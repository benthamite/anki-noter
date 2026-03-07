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
(require 'anki-noter-prompts)

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
  :type '(choice (const :tag "Same as source" nil)
                 (string :tag "Language"))
  :group 'anki-noter)

(defcustom anki-noter-anki-format nil
  "Value for the ANKI_FORMAT property on generated cards."
  :type '(choice (const :tag "nil (org-mode format)" nil)
                 (string :tag "Format"))
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
      (read-string "Anki deck: ")))

(defun anki-noter--get-tags ()
  "Get Anki tags, inheriting from org context or prompting."
  (or (anki-noter--inherit-property "ANKI_TAGS")
      (read-string "Anki tags (space-separated): ")))

;;;; Existing cards (incremental generation)

(defun anki-noter--existing-card-fronts ()
  "Collect front text of existing anki-editor sibling headings."
  (let ((cards '()))
    (save-excursion
      (when (org-up-heading-safe)
        (org-map-entries
         (lambda ()
           (when (org-entry-get nil "ANKI_NOTE_TYPE")
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
    (when (string-match "\\`\\s-*```[a-z]*\n?" text)
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
    (user-error "gptel is not configured. Set up a backend with `gptel-make-openai' or similar"))
  (if file
      ;; Use gptel-context for file-based input
      (progn
        (gptel-context-add-file file)
        (gptel-request content
          :system system-prompt
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
                           (and (org-back-to-heading t)
                                (org-outline-level)))
                         0)))))
    (setq anki-noter--heading-level level)
    (setq anki-noter--insertion-marker (point-marker))
    ;; Move to end of current subtree for insertion
    (when (org-at-heading-p)
      (org-end-of-subtree t)
      (set-marker anki-noter--insertion-marker (point)))))

(defun anki-noter--read-options (arg)
  "Read generation options when ARG is non-nil.
Return a plist with :template, :card-count, :topic."
  (if arg
      (let ((template (completing-read "Template: "
                                       (mapcar #'car anki-noter-prompt-templates)
                                       nil t nil nil anki-noter-default-template))
            (count (let ((input (read-string "Card count (empty = LLM decides): ")))
                     (if (string-empty-p input) nil (string-to-number input))))
            (topic (let ((input (read-string "Topic focus (empty = none): ")))
                     (if (string-empty-p input) nil input))))
        (list :template template :card-count count :topic topic))
    (list :template anki-noter-default-template
          :card-count anki-noter-card-count
          :topic nil)))

;;;; Interactive commands

;;;###autoload
(defun anki-noter-generate (arg)
  "Generate Anki cards from the current buffer or active region.
With prefix ARG, prompt for template, card count, and topic focus."
  (interactive "P")
  (anki-noter--prepare-insertion-point)
  (let* ((options (anki-noter--read-options arg))
         (card-count (or (plist-get options :card-count)
                         (and arg nil)
                         anki-noter-card-count))
         (deck (anki-noter--get-deck))
         (tags (anki-noter--get-tags))
         (existing (anki-noter--existing-card-fronts))
         (cite (anki-noter--cite-buffer))
         (content (anki-noter--buffer-content))
         (system-prompt (anki-noter-prompts-build
                         (plist-get options :template)
                         deck tags
                         :card-count card-count
                         :language anki-noter-language
                         :cite-source cite
                         :existing-cards existing
                         :topic (plist-get options :topic))))
    (message "Generating Anki cards...")
    (anki-noter--send content system-prompt #'anki-noter--insert-cards)))

;;;###autoload
(defun anki-noter-generate-from-file (file arg)
  "Generate Anki cards from FILE.
With prefix ARG, prompt for template, card count, and topic focus."
  (interactive "fFile: \nP")
  (anki-noter--prepare-insertion-point)
  (let* ((options (anki-noter--read-options arg))
         (card-count (or (plist-get options :card-count) anki-noter-card-count))
         (deck (anki-noter--get-deck))
         (tags (anki-noter--get-tags))
         (existing (anki-noter--existing-card-fronts))
         (ext (downcase (or (file-name-extension file) "")))
         (is-pdf (string= ext "pdf"))
         (page-range (when is-pdf
                       (let ((input (read-string "Page range (e.g. 1-20, empty = all): ")))
                         (unless (string-empty-p input) input))))
         (cite (anki-noter--cite-file file page-range))
         (system-prompt (anki-noter-prompts-build
                         (plist-get options :template)
                         deck tags
                         :card-count card-count
                         :language anki-noter-language
                         :cite-source cite
                         :existing-cards existing
                         :topic (plist-get options :topic))))
    (message "Generating Anki cards from %s..." (file-name-nondirectory file))
    (cond
     ;; PDF with native support
     ((and is-pdf (anki-noter--pdf-native-p))
      (anki-noter--send nil system-prompt #'anki-noter--insert-cards file))
     ;; PDF without native support — extract text
     (is-pdf
      (let ((text (anki-noter--extract-pdf-text file)))
        (anki-noter--send text system-prompt #'anki-noter--insert-cards)))
     ;; Text-based file — add to gptel-context
     (t
      (anki-noter--send nil system-prompt #'anki-noter--insert-cards file)))))

;;;###autoload
(defun anki-noter-generate-from-url (url arg)
  "Generate Anki cards from URL.
With prefix ARG, prompt for template, card count, and topic focus."
  (interactive "sURL: \nP")
  (anki-noter--prepare-insertion-point)
  (let* ((options (anki-noter--read-options arg))
         (card-count (or (plist-get options :card-count) anki-noter-card-count))
         (deck (anki-noter--get-deck))
         (tags (anki-noter--get-tags))
         (existing (anki-noter--existing-card-fronts))
         (cite (anki-noter--cite-url url))
         (system-prompt (anki-noter-prompts-build
                         (plist-get options :template)
                         deck tags
                         :card-count card-count
                         :language anki-noter-language
                         :cite-source cite
                         :existing-cards existing
                         :topic (plist-get options :topic))))
    (message "Fetching %s..." url)
    (anki-noter--fetch-url
     url
     (lambda (text)
       (message "Generating Anki cards from URL...")
       (anki-noter--send text system-prompt #'anki-noter--insert-cards)))))

;;;###autoload
(defun anki-noter-select-template ()
  "Interactively select a prompt template."
  (interactive)
  (let ((name (completing-read "Template: "
                               (mapcar #'car anki-noter-prompt-templates)
                               nil t nil nil anki-noter-default-template)))
    (setq anki-noter-default-template name)
    (message "Template set to: %s" name)))

(provide 'anki-noter)
;;; anki-noter.el ends here
