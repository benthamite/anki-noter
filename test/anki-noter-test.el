;;; anki-noter-test.el --- Tests for anki-noter.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for heading manipulation, citation formatting, content extraction,
;; org property inheritance, insertion logic, and insertion point setup in
;; anki-noter.el.

;;; Code:

(require 'ert)
(require 'org)
(require 'anki-noter)

;;;; Helper macro

(defmacro anki-noter-test--with-org-buffer (contents &rest body)
  "Create a temp org-mode buffer with CONTENTS, execute BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert ,contents)
     (goto-char (point-min))
     ,@body))

;;;; anki-noter--adjust-heading-levels

(ert-deftest anki-noter--adjust-heading-levels/no-headings ()
  "Text with no headings should be returned unchanged."
  (should (equal "Just some text\nwith lines.\n"
                 (anki-noter--adjust-heading-levels "Just some text\nwith lines.\n" 3))))

(ert-deftest anki-noter--adjust-heading-levels/single-heading-at-target ()
  "A heading already at target level should not change."
  (let ((text "*** Heading\nBody text\n"))
    (should (equal text (anki-noter--adjust-heading-levels text 3)))))

(ert-deftest anki-noter--adjust-heading-levels/shift-up ()
  "Headings at level 1 should shift up to target level 3."
  (let ((result (anki-noter--adjust-heading-levels "* Card front\nBody\n** Sub\n" 3)))
    (should (string-match-p "^\\*\\*\\* Card front" result))
    (should (string-match-p "^\\*\\*\\*\\* Sub" result))))

(ert-deftest anki-noter--adjust-heading-levels/shift-down ()
  "Headings at level 5 should shift down to target level 2."
  (let ((result (anki-noter--adjust-heading-levels "***** Deep heading\nBody\n" 2)))
    (should (string-match-p "^\\*\\* Deep heading" result))))

(ert-deftest anki-noter--adjust-heading-levels/preserves-relative-levels ()
  "Relative heading levels should be preserved after adjustment."
  (let ((result (anki-noter--adjust-heading-levels
                 "* Top\n** Sub\n*** SubSub\n" 4)))
    (should (string-match-p "^\\*\\*\\*\\* Top" result))
    (should (string-match-p "^\\*\\*\\*\\*\\* Sub" result))
    (should (string-match-p "^\\*\\*\\*\\*\\*\\* SubSub" result))))

(ert-deftest anki-noter--adjust-heading-levels/minimum-level-is-one ()
  "Headings should never be shifted below level 1."
  (let ((result (anki-noter--adjust-heading-levels "*** Heading\n" 1)))
    (should (string-match-p "^\\* Heading" result))))

(ert-deftest anki-noter--adjust-heading-levels/preserves-body-text ()
  "Body text between headings should be preserved."
  (let ((result (anki-noter--adjust-heading-levels
                 "* Q1\nAnswer one\n* Q2\nAnswer two\n" 2)))
    (should (string-match-p "Answer one" result))
    (should (string-match-p "Answer two" result))))

(ert-deftest anki-noter--adjust-heading-levels/preserves-property-drawers ()
  "Property drawers should pass through unchanged."
  (let* ((text "* Card\n:PROPERTIES:\n:ANKI_DECK: Test\n:END:\nBody\n")
         (result (anki-noter--adjust-heading-levels text 3)))
    (should (string-match-p ":PROPERTIES:" result))
    (should (string-match-p ":ANKI_DECK: Test" result))
    (should (string-match-p ":END:" result))))

(ert-deftest anki-noter--adjust-heading-levels/stars-in-body-not-affected ()
  "Stars that don't start at beginning of line should not be affected."
  (let* ((text "* Heading\nSome text with ** in it\n")
         (result (anki-noter--adjust-heading-levels text 2)))
    (should (string-match-p "with \\*\\* in it" result))))

;;;; anki-noter--count-headings

(ert-deftest anki-noter--count-headings/no-headings ()
  "Text with no headings should return 0."
  (should (= 0 (anki-noter--count-headings "Just text\nMore text\n"))))

(ert-deftest anki-noter--count-headings/single-heading ()
  (should (= 1 (anki-noter--count-headings "*** Card front\nBody\n"))))

(ert-deftest anki-noter--count-headings/multiple-headings ()
  (should (= 3 (anki-noter--count-headings
                "*** Q1\nA1\n*** Q2\nA2\n*** Q3\nA3\n"))))

(ert-deftest anki-noter--count-headings/mixed-levels ()
  "All heading levels should be counted."
  (should (= 3 (anki-noter--count-headings "* H1\n** H2\n*** H3\n"))))

(ert-deftest anki-noter--count-headings/empty-string ()
  (should (= 0 (anki-noter--count-headings ""))))

(ert-deftest anki-noter--count-headings/stars-in-body-not-counted ()
  "Stars not followed by a space at bol should not be counted."
  (should (= 1 (anki-noter--count-headings "* Heading\n**bold** text\n"))))

;;;; anki-noter--cite-file

(ert-deftest anki-noter--cite-file/simple-file ()
  "Citation for a simple file should use italicized basename without extension."
  (should (equal "/mybook/" (anki-noter--cite-file "/path/to/mybook.pdf"))))

(ert-deftest anki-noter--cite-file/with-page-range ()
  "Citation with page range should include pp. notation."
  (should (equal "/mybook/, pp. 10-20"
                 (anki-noter--cite-file "/path/to/mybook.pdf" "10-20"))))

(ert-deftest anki-noter--cite-file/no-page-range ()
  "Nil page range should produce citation without pp."
  (let ((result (anki-noter--cite-file "/some/dir/chapter.org" nil)))
    (should (equal "/chapter/" result))))

(ert-deftest anki-noter--cite-file/nested-path ()
  "Only the filename (no directory) should appear in citation."
  (let ((result (anki-noter--cite-file "/a/b/c/d/notes.txt")))
    (should (equal "/notes/" result))
    (should-not (string-match-p "/a/b/" result))))

(ert-deftest anki-noter--cite-file/file-without-extension ()
  "A file with no extension should still produce a citation."
  (should (equal "/README/" (anki-noter--cite-file "/path/README"))))

;;;; anki-noter--cite-url

(ert-deftest anki-noter--cite-url/returns-url-as-is ()
  "URL citation should return the URL unchanged."
  (should (equal "https://example.com/page" (anki-noter--cite-url "https://example.com/page"))))

;;;; anki-noter--cite-buffer

(ert-deftest anki-noter--cite-buffer/file-backed-buffer ()
  "For a file-backed buffer, citation should be the filename."
  (let ((temp-file (make-temp-file "anki-noter-test" nil ".org")))
    (unwind-protect
        (with-current-buffer (find-file-noselect temp-file)
          (should (equal (file-name-nondirectory temp-file)
                         (anki-noter--cite-buffer)))
          (kill-buffer))
      (delete-file temp-file))))

(ert-deftest anki-noter--cite-buffer/non-file-buffer ()
  "For a non-file buffer, citation should be the buffer name."
  (with-temp-buffer
    (rename-buffer "test-buffer" t)
    (should (equal (buffer-name) (anki-noter--cite-buffer)))))

;;;; anki-noter--inherit-property

(ert-deftest anki-noter--inherit-property/finds-parent-property ()
  "Should find a property set on a parent heading."
  (anki-noter-test--with-org-buffer
      "* Parent\n:PROPERTIES:\n:ANKI_DECK: TestDeck\n:END:\n** Child\n"
    (search-forward "** Child")
    (beginning-of-line)
    (should (equal "TestDeck" (anki-noter--inherit-property "ANKI_DECK")))))

(ert-deftest anki-noter--inherit-property/finds-grandparent-property ()
  "Should walk up multiple levels to find a property."
  (anki-noter-test--with-org-buffer
      "* Grand\n:PROPERTIES:\n:ANKI_DECK: TopDeck\n:END:\n** Parent\n*** Child\n"
    (search-forward "*** Child")
    (beginning-of-line)
    (should (equal "TopDeck" (anki-noter--inherit-property "ANKI_DECK")))))

(ert-deftest anki-noter--inherit-property/returns-nil-when-not-found ()
  "Should return nil when no ancestor has the property."
  (anki-noter-test--with-org-buffer
      "* Parent\n** Child\n"
    (search-forward "** Child")
    (beginning-of-line)
    (should-not (anki-noter--inherit-property "ANKI_DECK"))))

(ert-deftest anki-noter--inherit-property/closest-ancestor-wins ()
  "Should return the property from the closest ancestor."
  (anki-noter-test--with-org-buffer
      "* Grand\n:PROPERTIES:\n:ANKI_DECK: GrandDeck\n:END:\n** Parent\n:PROPERTIES:\n:ANKI_DECK: ParentDeck\n:END:\n*** Child\n"
    (search-forward "*** Child")
    (beginning-of-line)
    (should (equal "ParentDeck" (anki-noter--inherit-property "ANKI_DECK")))))

;;;; anki-noter--existing-card-fronts

(ert-deftest anki-noter--existing-card-fronts/collects-sibling-cards ()
  "Should collect front text of sibling headings with ANKI_NOTE_TYPE."
  (anki-noter-test--with-org-buffer
      "* Parent\n** Card 1\n:PROPERTIES:\n:ANKI_NOTE_TYPE: Basic\n:END:\nAnswer 1\n** Card 2\n:PROPERTIES:\n:ANKI_NOTE_TYPE: Basic\n:END:\nAnswer 2\n** Not a card\nJust text\n"
    (search-forward "** Not a card")
    (beginning-of-line)
    (let ((cards (anki-noter--existing-card-fronts)))
      (should (= 2 (length cards)))
      (should (member "Card 1" cards))
      (should (member "Card 2" cards)))))

(ert-deftest anki-noter--existing-card-fronts/empty-when-no-cards ()
  "Should return empty list when no siblings have ANKI_NOTE_TYPE."
  (anki-noter-test--with-org-buffer
      "* Parent\n** Just a heading\nSome text\n"
    (search-forward "** Just a heading")
    (beginning-of-line)
    (should (null (anki-noter--existing-card-fronts)))))

(ert-deftest anki-noter--existing-card-fronts/empty-at-top-level ()
  "Should return empty list when point is at top level (no parent)."
  (anki-noter-test--with-org-buffer
      "Top level text\n"
    (should (null (anki-noter--existing-card-fronts)))))

;;;; anki-noter--buffer-content

(ert-deftest anki-noter--buffer-content/returns-full-buffer ()
  "Without an active region, should return the entire buffer content."
  (with-temp-buffer
    (insert "Line 1\nLine 2\nLine 3\n")
    (should (equal "Line 1\nLine 2\nLine 3\n" (anki-noter--buffer-content)))))

(ert-deftest anki-noter--buffer-content/returns-region-when-active ()
  "With an active region, should return only the selected text."
  (with-temp-buffer
    (insert "Line 1\nLine 2\nLine 3\n")
    (goto-char (point-min))
    (search-forward "Line 2")
    (set-mark (match-beginning 0))
    (goto-char (match-end 0))
    (activate-mark)
    (should (equal "Line 2" (anki-noter--buffer-content)))
    (deactivate-mark)))

;;;; anki-noter--pdf-native-p

(ert-deftest anki-noter--pdf-native-p/nil-when-no-backend ()
  "Should return nil when gptel-backend is nil."
  (let ((gptel-backend nil))
    (should-not (anki-noter--pdf-native-p))))

;;;; anki-noter--insert-cards: code block stripping

(ert-deftest anki-noter--insert-cards/strips-leading-code-fence ()
  "Code block wrapper at the start of response should be stripped."
  (anki-noter-test--with-org-buffer
      "* Parent\n"
    (goto-char (point-max))
    (let ((anki-noter--insertion-marker (point-marker))
          (anki-noter--heading-level 2)
          (anki-noter--card-count-generated 0))
      ;; Prevent anki-noter--maybe-push from prompting
      (cl-letf (((symbol-function 'anki-noter--maybe-push) #'ignore))
        (anki-noter--insert-cards "```org\n** Card front\nBody\n```"))
      (should (string-match-p "^\\*\\* Card front" (buffer-string)))
      (should-not (string-match-p "```" (buffer-string))))))

(ert-deftest anki-noter--insert-cards/strips-code-fence-with-language ()
  "Code fences with a language tag should also be stripped."
  (anki-noter-test--with-org-buffer
      "* Parent\n"
    (goto-char (point-max))
    (let ((anki-noter--insertion-marker (point-marker))
          (anki-noter--heading-level 2)
          (anki-noter--card-count-generated 0))
      (cl-letf (((symbol-function 'anki-noter--maybe-push) #'ignore))
        (anki-noter--insert-cards "```markdown\n** Card\nBody\n```"))
      (should-not (string-match-p "```" (buffer-string))))))

(ert-deftest anki-noter--insert-cards/no-code-fence-passthrough ()
  "Response without code fences should pass through normally."
  (anki-noter-test--with-org-buffer
      "* Parent\n"
    (goto-char (point-max))
    (let ((anki-noter--insertion-marker (point-marker))
          (anki-noter--heading-level 2)
          (anki-noter--card-count-generated 0))
      (cl-letf (((symbol-function 'anki-noter--maybe-push) #'ignore))
        (anki-noter--insert-cards "** Card front\nBody text\n"))
      (should (string-match-p "Card front" (buffer-string)))
      (should (string-match-p "Body text" (buffer-string))))))

;;;; anki-noter--insert-cards: heading level adjustment

(ert-deftest anki-noter--insert-cards/adjusts-heading-levels ()
  "Inserted cards should have headings at the correct level."
  (anki-noter-test--with-org-buffer
      "* Parent\n"
    (goto-char (point-max))
    (let ((anki-noter--insertion-marker (point-marker))
          (anki-noter--heading-level 3)
          (anki-noter--card-count-generated 0))
      (cl-letf (((symbol-function 'anki-noter--maybe-push) #'ignore))
        (anki-noter--insert-cards "* Card front\nBody\n"))
      (should (string-match-p "^\\*\\*\\* Card front" (buffer-string))))))

;;;; anki-noter--insert-cards: card count tracking

(ert-deftest anki-noter--insert-cards/counts-generated-cards ()
  "The card count variable should reflect the number of inserted headings."
  (anki-noter-test--with-org-buffer
      "* Parent\n"
    (goto-char (point-max))
    (let ((anki-noter--insertion-marker (point-marker))
          (anki-noter--heading-level 2)
          (anki-noter--card-count-generated 0))
      (cl-letf (((symbol-function 'anki-noter--maybe-push) #'ignore))
        (anki-noter--insert-cards "** Q1\nA1\n** Q2\nA2\n** Q3\nA3\n"))
      (should (= 3 anki-noter--card-count-generated)))))

;;;; anki-noter--prepare-insertion-point

(ert-deftest anki-noter--prepare-insertion-point/errors-outside-org-mode ()
  "Should signal an error when not in an org-mode buffer."
  (with-temp-buffer
    (fundamental-mode)
    (should-error (anki-noter--prepare-insertion-point)
                  :type 'user-error)))

(ert-deftest anki-noter--prepare-insertion-point/sets-heading-level-at-heading ()
  "When on a heading, target level should be one deeper."
  (anki-noter-test--with-org-buffer
      "* Top\n** Sub\n"
    (search-forward "** Sub")
    (beginning-of-line)
    (anki-noter--prepare-insertion-point)
    (should (= 3 anki-noter--heading-level))))

(ert-deftest anki-noter--prepare-insertion-point/sets-marker ()
  "The insertion marker should be set to a valid marker."
  (anki-noter-test--with-org-buffer
      "* Heading\n"
    (goto-char (point-min))
    (anki-noter--prepare-insertion-point)
    (should (markerp anki-noter--insertion-marker))
    (should (buffer-live-p (marker-buffer anki-noter--insertion-marker)))))

(ert-deftest anki-noter--prepare-insertion-point/level-1-heading ()
  "At a level-1 heading, target should be level 2."
  (anki-noter-test--with-org-buffer
      "* Top\nBody\n"
    (goto-char (point-min))
    (anki-noter--prepare-insertion-point)
    (should (= 2 anki-noter--heading-level))))

;;;; anki-noter--extract-pdf-text

(ert-deftest anki-noter--extract-pdf-text/errors-on-nonexistent-file ()
  "Should signal an error when the PDF file doesn't exist."
  (let ((anki-noter-pdf-fallback-command "pdftotext %s -"))
    (should-error (anki-noter--extract-pdf-text "/nonexistent/file.pdf")
                  :type 'user-error)))

;;;; Edge cases: insert-cards with whitespace

(ert-deftest anki-noter--insert-cards/trims-whitespace ()
  "Surrounding whitespace in the response should be trimmed."
  (anki-noter-test--with-org-buffer
      "* Parent\n"
    (goto-char (point-max))
    (let ((anki-noter--insertion-marker (point-marker))
          (anki-noter--heading-level 2)
          (anki-noter--card-count-generated 0))
      (cl-letf (((symbol-function 'anki-noter--maybe-push) #'ignore))
        (anki-noter--insert-cards "\n\n  ** Card\nBody\n\n  "))
      (should (string-match-p "Card" (buffer-string))))))

(ert-deftest anki-noter--insert-cards/empty-response ()
  "An empty response should insert nothing and count 0 cards."
  (anki-noter-test--with-org-buffer
      "* Parent\n"
    (goto-char (point-max))
    (let ((anki-noter--insertion-marker (point-marker))
          (anki-noter--heading-level 2)
          (anki-noter--card-count-generated 0)
          (before (buffer-string)))
      (cl-letf (((symbol-function 'anki-noter--maybe-push) #'ignore))
        (anki-noter--insert-cards "   "))
      (should (= 0 anki-noter--card-count-generated)))))

;;;; Integration: adjust + count roundtrip

(ert-deftest anki-noter--adjust-then-count/consistent ()
  "Adjusting heading levels should not change the heading count."
  (let* ((text "* A\n** B\n*** C\n* D\n")
         (adjusted (anki-noter--adjust-heading-levels text 3))
         (original-count (anki-noter--count-headings text))
         (adjusted-count (anki-noter--count-headings adjusted)))
    (should (= original-count adjusted-count))))

(provide 'anki-noter-test)
;;; anki-noter-test.el ends here
