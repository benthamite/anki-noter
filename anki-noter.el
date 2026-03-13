;;; anki-noter.el --- Generate Anki flashcards from source material via LLM -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Pablo Stafforini

;; Author: Pablo Stafforini
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (gptel "0.9") (anki-editor "0.3"))
;; Keywords: tools, outlines
;; URL: https://github.com/benthamite/anki-noter

;; This file is part of anki-noter.

;;; Commentary:

;; An Emacs Lisp package that uses an LLM (via gptel) to generate Anki
;; flashcards from various source materials and inserts them as org-mode
;; headings formatted for anki-editor.

;;; Code:

(require 'org)
(require 'gptel)
(require 'anki-editor)
(require 'transient)
(require 'anki-noter-prompts)

(declare-function gptel-context-add-file "gptel-context" (path))
(declare-function gptel-context-remove "gptel-context" (&optional context))

;;;; Customization

(defgroup anki-noter nil
  "Generate Anki flashcards via LLM."
  :group 'tools
  :prefix "anki-noter-")

(defcustom anki-noter-card-count nil
  "Default target number of cards to generate.
When nil, the LLM decides the appropriate number."
  :type '(choice (const :tag "LLM decides" nil)
                 (integer :tag "Target count"))
  :group 'anki-noter)

(defcustom anki-noter-default-template "general"
  "Default prompt template name."
  :type 'string
  :group 'anki-noter)

(defcustom anki-noter-language nil
  "Output language for generated cards.
When nil, cards are generated in the same language as the source."
  :type '(choice (const :tag "Inherit source" nil)
                 (string :tag "Language"))
  :group 'anki-noter)

(defcustom anki-noter-anki-format nil
  "Value for the ANKI_FORMAT property on generated cards."
  :type '(choice (const :tag "nil (org-mode format)" nil)
                 (string :tag "Format"))
  :group 'anki-noter)

(defcustom anki-noter-cite-sources nil
  "If non-nil, append a source citation to each card back."
  :type 'boolean
  :group 'anki-noter)

(defcustom anki-noter-cite-format "Source: %s"
  "Format string for source citation appended to card backs.
%s is replaced with the source description."
  :type 'string
  :group 'anki-noter)

(defcustom anki-noter-pdf-fallback-command "pdftotext %s -"
  "Command for PDF text extraction when native PDF input is unavailable.
%s is replaced with the file path."
  :type 'string
  :group 'anki-noter)

(defcustom anki-noter-auto-push nil
  "If non-nil, push new notes to Anki automatically without prompting."
  :type 'boolean
  :group 'anki-noter)

;;;; Internal variables

(defvar anki-noter--insertion-marker nil
  "Marker for where to insert generated cards.")

(defvar anki-noter--heading-level nil
  "Heading level for generated cards.")

(defvar anki-noter--card-count-generated 0
  "Number of cards generated in the last invocation.")

;;;; Deck and tags

(defun anki-noter--inherit-property (property)
  "Walk up the org tree looking for PROPERTY, return its value or nil."
  (save-excursion
    (let ((value nil))
      (while (and (not value) (org-up-heading-safe))
        (setq value (org-entry-get nil property)))
      (unless value
        (setq value (org-entry-get nil property t)))
      value)))

(defun anki-noter--get-deck ()
  "Get the Anki deck, inheriting from org context or prompting."
  (or (anki-noter--inherit-property "ANKI_DECK")
      (completing-read "Anki deck: " (anki-editor-deck-names) nil t)))

(defun anki-noter--get-tags ()
  "Get Anki tags, inheriting from org context or prompting."
  (or (anki-noter--inherit-property "ANKI_TAGS")
      (mapconcat #'identity
                 (completing-read-multiple "Anki tags (comma-separated): " (anki-editor-all-tags))
                 " ")))

;;;; Existing cards (incremental generation)

(defun anki-noter--existing-card-fronts ()
  "Collect front text of existing anki-editor sibling headings.
Only direct children of the parent heading are considered."
  (let ((cards '())
        (child-level nil))
    (save-excursion
      (when (org-up-heading-safe)
        (setq child-level (1+ (org-outline-level)))
        (org-map-entries
         (lambda ()
           (when (and (= (org-outline-level) child-level)
                      (org-entry-get nil "ANKI_NOTE_TYPE"))
             (push (org-get-heading t t t t) cards)))
         nil 'tree)))
    (nreverse cards)))

;;;; Source citation

(defun anki-noter--cite-buffer ()
  "Return citation string for the current buffer."
  (if-let ((file (buffer-file-name)))
      (file-name-nondirectory file)
    (buffer-name)))

(defun anki-noter--cite-file (file &optional page-range)
  "Return citation string for FILE, optionally with PAGE-RANGE."
  (let ((name (file-name-nondirectory file)))
    (if page-range
        (format "/%s/, pp. %s" (file-name-sans-extension name) page-range)
      (format "/%s/" (file-name-sans-extension name)))))

(defun anki-noter--cite-url (url)
  "Return citation string for URL."
  url)

;;;; Content extraction

(defun anki-noter--buffer-content ()
  "Get content from current buffer or active region."
  (if (use-region-p)
      (buffer-substring-no-properties (region-beginning) (region-end))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun anki-noter--pdf-native-p ()
  "Return non-nil if the current gptel backend supports native PDF input."
  (when-let ((backend gptel-backend))
    (let ((name (gptel-backend-name backend)))
      (or (string-match-p "claude\\|anthropic" (downcase name))
          (string-match-p "gemini\\|google" (downcase name))))))

(defun anki-noter--extract-pdf-text (file)
  "Extract text from PDF FILE using the fallback command."
  (let ((command (format anki-noter-pdf-fallback-command
                         (shell-quote-argument (expand-file-name file)))))
    (with-temp-buffer
      (let ((exit-code (call-process-shell-command command nil t)))
        (if (zerop exit-code)
            (buffer-string)
          (user-error "PDF text extraction failed (exit code %d). Install pdftotext or configure `anki-noter-pdf-fallback-command'"
                      exit-code))))))

(defun anki-noter--fetch-url (url callback)
  "Fetch URL and call CALLBACK with the extracted text content."
  (url-retrieve
   url
   (lambda (status)
     (if-let ((err (plist-get status :error)))
         (user-error "Failed to fetch URL %s: %s" url err)
       (goto-char (point-min))
       (re-search-forward "\n\n" nil t)
       (let ((content (buffer-substring-no-properties (point) (point-max))))
         (with-temp-buffer
           (insert content)
           (shr-render-region (point-min) (point-max))
           (funcall callback (buffer-substring-no-properties
                              (point-min) (point-max)))))))
   nil t))

;;;; Response parsing and insertion

(defun anki-noter--adjust-heading-levels (text target-level)
  "Adjust org heading levels in TEXT so top-level headings are at TARGET-LEVEL."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    ;; Find the minimum heading level in the response
    (let ((min-level nil))
      (while (re-search-forward "^\\(\\*+\\) " nil t)
        (let ((level (length (match-string 1))))
          (when (or (null min-level) (< level min-level))
            (setq min-level level))))
      (when min-level
        (let ((delta (- target-level min-level)))
          (unless (zerop delta)
            (goto-char (point-min))
            (while (re-search-forward "^\\(\\*+\\) " nil t)
              (let* ((stars (match-string 1))
                     (new-level (+ (length stars) delta))
                     (new-stars (make-string (max 1 new-level) ?*)))
                (replace-match (concat new-stars " "))))))))
    (buffer-string)))

(defun anki-noter--count-headings (text)
  "Count the number of org headings in TEXT."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let ((count 0))
      (while (re-search-forward "^\\*+ " nil t)
        (cl-incf count))
      count)))

(defun anki-noter--insert-cards (response)
  "Insert RESPONSE (org headings from LLM) at the insertion marker."
  ;; Strip code block wrappers if present
  (let ((text response))
    (when (string-match "\\`\\s-*```[a-zA-Z]*\n?" text)
      (setq text (replace-match "" nil nil text)))
    (when (string-match "\n?```\\s-*\\'" text)
      (setq text (replace-match "" nil nil text)))
    (setq text (string-trim text))
    ;; Adjust heading levels
    (setq text (anki-noter--adjust-heading-levels text anki-noter--heading-level))
    (setq anki-noter--card-count-generated (anki-noter--count-headings text))
    (with-current-buffer (marker-buffer anki-noter--insertion-marker)
      (save-excursion
        (goto-char anki-noter--insertion-marker)
        ;; Ensure we're at the end of the current subtree
        (unless (bolp) (insert "\n"))
        (let ((start (point)))
          (insert text)
          (unless (= (char-before) ?\n) (insert "\n"))
          ;; Offer to push to Anki
          (anki-noter--maybe-push start (point)))))))

(defun anki-noter--maybe-push (start end)
  "Offer to push newly inserted cards between START and END to Anki."
  (when (require 'anki-editor nil t)
    (when (or anki-noter-auto-push
              (yes-or-no-p (format "Push %d new notes to Anki? "
                                   anki-noter--card-count-generated)))
      (save-excursion
        (save-restriction
          (narrow-to-region start end)
          (anki-editor-push-notes))))))

;;;; LLM request

(defun anki-noter--send (content system-prompt callback &optional file)
  "Send CONTENT with SYSTEM-PROMPT to the LLM via gptel.
CALLBACK is called with the response. If FILE is non-nil, add it to
gptel-context instead of sending content directly."
  (unless gptel-backend
    (user-error "The gptel dependency is not configured. Set up a backend with `gptel-make-openai' or similar"))
  (if file
      ;; Use gptel-context for file-based input
      (progn
        (gptel-context-add-file file)
        (gptel-request (or content "Generate Anki flashcards from the provided file.")
          :system system-prompt
          :transforms '(t)
          :callback (lambda (response info)
                      (gptel-context-remove)
                      (if (not response)
                          (user-error "LLM request failed: %s" (plist-get info :status))
                        (funcall callback response)))))
    (gptel-request content
      :system system-prompt
      :callback (lambda (response info)
                  (if (not response)
                      (user-error "LLM request failed: %s" (plist-get info :status))
                    (funcall callback response))))))

;;;; Setup helpers

(defun anki-noter--prepare-insertion-point ()
  "Set up the insertion marker and heading level at point."
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (let ((level (if (org-at-heading-p)
                   (1+ (org-outline-level))
                 (1+ (or (save-excursion
                           (and (condition-case nil
                                    (org-back-to-heading t)
                                  (error nil))
                                (org-outline-level)))
                         0)))))
    (setq anki-noter--heading-level level)
    (setq anki-noter--insertion-marker (point-marker))
    ;; Move to end of current subtree for insertion
    (when (org-at-heading-p)
      (org-end-of-subtree t)
      (set-marker anki-noter--insertion-marker (point)))))

;;;; Transient

(defun anki-noter--init-value (obj)
  "Initialize transient values for OBJ from defcustoms and org context."
  (oset obj value
        (delq nil
              (list
               (concat "--template=" (or anki-noter-default-template "general"))
               (when anki-noter-card-count
                 (concat "--count=" (number-to-string anki-noter-card-count)))
               (when anki-noter-language
                 (concat "--language=" anki-noter-language))
               (when anki-noter-cite-sources
                 "--cite")
               (when (derived-mode-p 'org-mode)
                 (when-let ((deck (anki-noter--inherit-property "ANKI_DECK")))
                   (concat "--deck=" deck)))
               (when (derived-mode-p 'org-mode)
                 (when-let ((tags (anki-noter--inherit-property "ANKI_TAGS")))
                   (concat "--tags=" tags)))))))

(defun anki-noter--transient-value (key args)
  "Extract the value of KEY from transient ARGS."
  (when-let ((arg (seq-find (lambda (a) (string-prefix-p key a)) args)))
    (substring arg (length key))))

(transient-define-infix anki-noter--infix-file ()
  :class 'transient-option
  :description "File"
  :key "f"
  :argument "--file="
  :reader (lambda (prompt _initial-input _history)
            (read-file-name prompt)))

(transient-define-infix anki-noter--infix-url ()
  :class 'transient-option
  :description "URL"
  :key "u"
  :argument "--url="
  :reader (lambda (prompt _initial-input _history)
            (read-string prompt)))

(transient-define-infix anki-noter--infix-range ()
  :class 'transient-option
  :description "Page range"
  :key "r"
  :argument "--range="
  :reader (lambda (prompt _initial-input _history)
            (read-string prompt)))

(transient-define-infix anki-noter--infix-deck ()
  :class 'transient-option
  :description "Deck"
  :key "d"
  :argument "--deck="
  :reader (lambda (prompt _initial-input _history)
            (completing-read prompt (anki-editor-deck-names) nil t)))

(transient-define-infix anki-noter--infix-tags ()
  :class 'transient-option
  :description "Tags"
  :key "t"
  :argument "--tags="
  :reader (lambda (prompt _initial-input _history)
            (mapconcat #'identity
                       (completing-read-multiple prompt (anki-editor-all-tags))
                       " ")))

(transient-define-infix anki-noter--infix-template ()
  :class 'transient-option
  :description "Template"
  :key "T"
  :argument "--template="
  :reader (lambda (prompt _initial-input _history)
            (completing-read prompt
                             (mapcar #'car anki-noter-prompt-templates)
                             nil t nil nil anki-noter-default-template)))

(transient-define-infix anki-noter--infix-count ()
  :class 'transient-option
  :description "Card count (LLM decides if unset)"
  :key "c"
  :argument "--count="
  :reader (lambda (prompt _initial-input _history)
            (read-string prompt)))

(transient-define-infix anki-noter--infix-language ()
  :class 'transient-option
  :description "Language (inherit source if unset)"
  :key "l"
  :argument "--language="
  :reader (lambda (prompt _initial-input _history)
            (read-string prompt)))

(transient-define-infix anki-noter--infix-topic ()
  :class 'transient-option
  :description "Topic focus"
  :key "o"
  :argument "--topic="
  :reader (lambda (prompt _initial-input _history)
            (read-string prompt)))

(transient-define-infix anki-noter--infix-cite ()
  :class 'transient-switch
  :description "Cite sources"
  :key "s"
  :argument "--cite")

;;;###autoload (autoload 'anki-noter "anki-noter" "Generate Anki flashcards from source material via LLM." t)
(transient-define-prefix anki-noter ()
  "Generate Anki flashcards from source material via LLM."
  :info-manual "(anki-noter)"
  :init-value #'anki-noter--init-value
  ["Source"
   (anki-noter--infix-file)
   (anki-noter--infix-url)
   (anki-noter--infix-range)]
  ["Target"
   (anki-noter--infix-deck)
   (anki-noter--infix-tags)]
  ["Options"
   (anki-noter--infix-template)
   (anki-noter--infix-count)
   (anki-noter--infix-language)
   (anki-noter--infix-topic)
   (anki-noter--infix-cite)]
  ["Actions"
   ("g" "Generate" anki-noter-generate)])

(defun anki-noter-generate (&optional args)
  "Generate Anki cards using the current transient settings.
ARGS is the list of transient arguments."
  (interactive (list (transient-args 'anki-noter)))
  (anki-noter--prepare-insertion-point)
  (let* ((file (anki-noter--transient-value "--file=" args))
         (url (anki-noter--transient-value "--url=" args))
         (range (anki-noter--transient-value "--range=" args))
         (deck (or (anki-noter--transient-value "--deck=" args)
                   (anki-noter--get-deck)))
         (tags (or (anki-noter--transient-value "--tags=" args)
                   (anki-noter--get-tags)))
         (template (or (anki-noter--transient-value "--template=" args)
                       anki-noter-default-template))
         (count-str (anki-noter--transient-value "--count=" args))
         (card-count (if (and count-str (not (string-empty-p count-str)))
                         (string-to-number count-str)
                       anki-noter-card-count))
         (language (or (anki-noter--transient-value "--language=" args)
                       anki-noter-language))
         (topic (anki-noter--transient-value "--topic=" args))
         (cite-p (or (member "--cite" args) anki-noter-cite-sources))
         (existing (anki-noter--existing-card-fronts))
         (cite (cond
                ((and cite-p file) (anki-noter--cite-file file range))
                ((and cite-p url) (anki-noter--cite-url url))
                (cite-p (anki-noter--cite-buffer))))
         (system-prompt (anki-noter-prompts-build
                         template deck tags
                         :card-count card-count
                         :language language
                         :cite-source cite
                         :existing-cards existing
                         :topic topic)))
    (cond
     ;; File source
     (file
      (let* ((ext (downcase (or (file-name-extension file) "")))
             (is-pdf (string= ext "pdf")))
        (message "Generating Anki cards from %s..." (file-name-nondirectory file))
        (cond
         ((and is-pdf (anki-noter--pdf-native-p))
          (anki-noter--send nil system-prompt #'anki-noter--insert-cards file))
         (is-pdf
          (let ((text (anki-noter--extract-pdf-text file)))
            (anki-noter--send text system-prompt #'anki-noter--insert-cards)))
         (t
          (anki-noter--send nil system-prompt #'anki-noter--insert-cards file)))))
     ;; URL source
     (url
      (message "Fetching %s..." url)
      (anki-noter--fetch-url
       url
       (lambda (text)
         (message "Generating Anki cards from URL...")
         (anki-noter--send text system-prompt #'anki-noter--insert-cards))))
     ;; Buffer/region source
     (t
      (message "Generating Anki cards from buffer...")
      (anki-noter--send (anki-noter--buffer-content) system-prompt
                        #'anki-noter--insert-cards)))))

(provide 'anki-noter)
;;; anki-noter.el ends here
