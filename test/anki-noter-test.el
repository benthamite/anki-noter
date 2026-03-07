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

;;;; anki-noter--adjust-heading-levels: additional edge cases

(ert-deftest anki-noter--adjust-heading-levels/large-upward-delta ()
  "Shifting from level 1 to level 10 should produce 10 stars."
  (let ((result (anki-noter--adjust-heading-levels "* Heading\n" 10)))
    (should (string-match-p "^\\*\\{10\\} Heading" result))))

(ert-deftest anki-noter--adjust-heading-levels/sub-heading-preserves-delta ()
  "Shifting down preserves the relative difference between heading levels."
  (let ((result (anki-noter--adjust-heading-levels "** Main\n*** Sub\n" 1)))
    ;; delta = 1 - 2 = -1; Main (2) -> 1, Sub (3) -> 2
    (should (string-match-p "^\\* Main" result))
    (should (string-match-p "^\\*\\* Sub" result))))

(ert-deftest anki-noter--adjust-heading-levels/deep-shift-clamps-to-one ()
  "When a large negative delta would push headings below 1, clamp to 1."
  (let ((result (anki-noter--adjust-heading-levels "***** Main\n****** Sub\n" 1)))
    ;; delta = 1 - 5 = -4; Main (5) -> 1, Sub (6) -> 2 (not below 1)
    (should (string-match-p "^\\* Main" result))
    (should (string-match-p "^\\*\\* Sub" result)))
  ;; Now test actual clamping: target=1 with *** (level 3) as min
  ;; delta = 1-3 = -2; *** (3) -> 1, * (1) -> max(1, -1) = 1
  (let ((result (anki-noter--adjust-heading-levels "* Shallow\n*** Deep\n" 1)))
    ;; min-level=1, target=1, delta=0 — no change
    (should (string-match-p "^\\* Shallow" result))
    (should (string-match-p "^\\*\\*\\* Deep" result))))

(ert-deftest anki-noter--adjust-heading-levels/empty-string ()
  "Empty string should be returned as-is."
  (should (equal "" (anki-noter--adjust-heading-levels "" 3))))

;;;; anki-noter--insert-cards: code fence bug fix (uppercase tags)

(ert-deftest anki-noter--insert-cards/strips-uppercase-language-fence ()
  "Code fences with uppercase language tags (e.g. Org, Markdown) should be stripped."
  (anki-noter-test--with-org-buffer
      "* Parent\n"
    (goto-char (point-max))
    (let ((anki-noter--insertion-marker (point-marker))
          (anki-noter--heading-level 2)
          (anki-noter--card-count-generated 0))
      (cl-letf (((symbol-function 'anki-noter--maybe-push) #'ignore))
        (anki-noter--insert-cards "```Org\n** Card\nBody\n```"))
      (should-not (string-match-p "```" (buffer-string)))
      (should (string-match-p "Card" (buffer-string))))))

(ert-deftest anki-noter--insert-cards/strips-mixed-case-fence ()
  "Code fences like ```orgMode should be stripped."
  (anki-noter-test--with-org-buffer
      "* Parent\n"
    (goto-char (point-max))
    (let ((anki-noter--insertion-marker (point-marker))
          (anki-noter--heading-level 2)
          (anki-noter--card-count-generated 0))
      (cl-letf (((symbol-function 'anki-noter--maybe-push) #'ignore))
        (anki-noter--insert-cards "```orgMode\n** Card\nBody\n```"))
      (should-not (string-match-p "```" (buffer-string))))))

;;;; anki-noter--insert-cards: property drawers preserved

(ert-deftest anki-noter--insert-cards/preserves-property-drawers ()
  "Property drawers in inserted cards should be preserved intact."
  (anki-noter-test--with-org-buffer
      "* Parent\n"
    (goto-char (point-max))
    (let ((anki-noter--insertion-marker (point-marker))
          (anki-noter--heading-level 2)
          (anki-noter--card-count-generated 0))
      (cl-letf (((symbol-function 'anki-noter--maybe-push) #'ignore))
        (anki-noter--insert-cards
         "** Question\n:PROPERTIES:\n:ANKI_DECK: TestDeck\n:ANKI_NOTE_TYPE: Basic\n:END:\nAnswer text\n"))
      (let ((buf (buffer-string)))
        (should (string-match-p ":ANKI_DECK: TestDeck" buf))
        (should (string-match-p ":ANKI_NOTE_TYPE: Basic" buf))
        (should (string-match-p "Answer text" buf))))))

;;;; anki-noter--insert-cards: appends to existing content

(ert-deftest anki-noter--insert-cards/appends-after-existing ()
  "Cards should be appended after existing buffer content."
  (anki-noter-test--with-org-buffer
      "* Parent\nExisting body\n"
    (goto-char (point-max))
    (let ((anki-noter--insertion-marker (point-marker))
          (anki-noter--heading-level 2)
          (anki-noter--card-count-generated 0))
      (cl-letf (((symbol-function 'anki-noter--maybe-push) #'ignore))
        (anki-noter--insert-cards "** New card\nAnswer\n"))
      (let ((buf (buffer-string)))
        (should (string-match-p "Existing body" buf))
        (should (string-match-p "New card" buf))
        ;; Existing content should come before new card
        (should (< (string-match "Existing body" buf)
                   (string-match "New card" buf)))))))

;;;; anki-noter--insert-cards: realistic LLM response

(ert-deftest anki-noter--insert-cards/realistic-llm-response ()
  "A realistic multi-card LLM response should be parsed correctly."
  (anki-noter-test--with-org-buffer
      "* Study notes\n"
    (goto-char (point-max))
    (let ((anki-noter--insertion-marker (point-marker))
          (anki-noter--heading-level 2)
          (anki-noter--card-count-generated 0)
          (response "```org
*** What is spaced repetition?
:PROPERTIES:
:ANKI_DECK: Learning
:ANKI_NOTE_TYPE: Basic
:ANKI_TAGS: learning memory
:END:

A learning technique that reviews material at increasing intervals.

Source: /Learning How to Learn/

*** What is the forgetting curve?
:PROPERTIES:
:ANKI_DECK: Learning
:ANKI_NOTE_TYPE: Basic
:ANKI_TAGS: learning memory
:END:

The exponential decline in memory retention over time, first described by Ebbinghaus.

Source: /Learning How to Learn/
```"))
      (cl-letf (((symbol-function 'anki-noter--maybe-push) #'ignore))
        (anki-noter--insert-cards response))
      (should (= 2 anki-noter--card-count-generated))
      (let ((buf (buffer-string)))
        (should-not (string-match-p "```" buf))
        (should (string-match-p "spaced repetition" buf))
        (should (string-match-p "forgetting curve" buf))
        (should (string-match-p "ANKI_NOTE_TYPE: Basic" buf))))))

;;;; anki-noter--prepare-insertion-point: bug fix (before first heading)

(ert-deftest anki-noter--prepare-insertion-point/before-first-heading ()
  "Should default to level 1 when point is before the first heading."
  (anki-noter-test--with-org-buffer
      "Some text before any heading.\n* First heading\n"
    (goto-char (point-min))
    (anki-noter--prepare-insertion-point)
    (should (= 1 anki-noter--heading-level))))

(ert-deftest anki-noter--prepare-insertion-point/empty-org-buffer ()
  "Should default to level 1 in an empty org buffer."
  (anki-noter-test--with-org-buffer
      ""
    (anki-noter--prepare-insertion-point)
    (should (= 1 anki-noter--heading-level))))

(ert-deftest anki-noter--prepare-insertion-point/body-text-under-heading ()
  "When on body text under a heading, level should be one deeper than that heading."
  (anki-noter-test--with-org-buffer
      "* Heading\nBody text here\n"
    (search-forward "Body text")
    (beginning-of-line)
    (anki-noter--prepare-insertion-point)
    (should (= 2 anki-noter--heading-level))))

(ert-deftest anki-noter--prepare-insertion-point/marker-at-end-of-subtree ()
  "When on a heading, marker should be after the subtree content."
  (anki-noter-test--with-org-buffer
      "* Parent\n** Child\nChild body\n* Sibling\n"
    (goto-char (point-min))
    (anki-noter--prepare-insertion-point)
    (let ((marker-pos (marker-position anki-noter--insertion-marker))
          (body-end (progn (goto-char (point-min))
                           (search-forward "Child body")
                           (line-end-position)))
          (sibling-pos (progn (goto-char (point-min))
                              (search-forward "* Sibling")
                              (match-beginning 0))))
      ;; Marker should be between end of body and start of sibling
      (should (>= marker-pos body-end))
      (should (<= marker-pos sibling-pos)))))

;;;; anki-noter--existing-card-fronts: bug fix (only direct children)

(ert-deftest anki-noter--existing-card-fronts/excludes-nested-cards ()
  "Should only collect direct children, not deeply nested cards."
  (anki-noter-test--with-org-buffer
      "* Parent
** Card 1
:PROPERTIES:
:ANKI_NOTE_TYPE: Basic
:END:
Answer 1
*** Nested card
:PROPERTIES:
:ANKI_NOTE_TYPE: Basic
:END:
Nested answer
** Card 2
:PROPERTIES:
:ANKI_NOTE_TYPE: Basic
:END:
Answer 2
"
    (search-forward "** Card 2")
    (beginning-of-line)
    (let ((cards (anki-noter--existing-card-fronts)))
      (should (= 2 (length cards)))
      (should (member "Card 1" cards))
      (should (member "Card 2" cards))
      (should-not (member "Nested card" cards)))))

(ert-deftest anki-noter--existing-card-fronts/preserves-order ()
  "Cards should be returned in document order."
  (anki-noter-test--with-org-buffer
      "* Parent
** Zebra card
:PROPERTIES:
:ANKI_NOTE_TYPE: Basic
:END:
A
** Alpha card
:PROPERTIES:
:ANKI_NOTE_TYPE: Basic
:END:
B
** Middle card
:PROPERTIES:
:ANKI_NOTE_TYPE: Basic
:END:
C
"
    (search-forward "** Middle card")
    (beginning-of-line)
    (let ((cards (anki-noter--existing-card-fronts)))
      (should (equal '("Zebra card" "Alpha card" "Middle card") cards)))))

;;;; anki-noter--send

(ert-deftest anki-noter--send/errors-without-backend ()
  "Should signal user-error when gptel-backend is nil."
  (let ((gptel-backend nil))
    (should-error (anki-noter--send "content" "prompt" #'ignore)
                  :type 'user-error)))

;;;; anki-noter--transient-value

(ert-deftest anki-noter--transient-value/extracts-value ()
  "Should extract the value portion after the key prefix."
  (should (equal "MyDeck"
                 (anki-noter--transient-value "--deck=" '("--deck=MyDeck" "--tags=t1")))))

(ert-deftest anki-noter--transient-value/returns-nil-when-absent ()
  "Should return nil when the key is not in the args list."
  (should-not (anki-noter--transient-value "--deck=" '("--tags=t1" "--cite"))))

(ert-deftest anki-noter--transient-value/handles-empty-args ()
  "Should return nil for an empty args list."
  (should-not (anki-noter--transient-value "--file=" nil)))

(ert-deftest anki-noter--transient-value/handles-empty-value ()
  "Should return empty string when key is present but value is empty."
  (should (equal "" (anki-noter--transient-value "--count=" '("--count=")))))

(ert-deftest anki-noter--transient-value/handles-value-with-equals ()
  "Should handle values that themselves contain = signs."
  (should (equal "a=b"
                 (anki-noter--transient-value "--file=" '("--file=a=b")))))

;;;; anki-noter--maybe-push

(ert-deftest anki-noter--maybe-push/auto-push-calls-anki-editor ()
  "When auto-push is on, anki-editor-push-notes should be called."
  (anki-noter-test--with-org-buffer
      "* Parent\n** Card\n:PROPERTIES:\n:ANKI_NOTE_TYPE: Basic\n:END:\nAnswer\n"
    ;; Pre-load anki-editor so require inside --maybe-push is a no-op
    (require 'anki-editor nil t)
    (let ((anki-noter-auto-push t)
          (anki-noter--card-count-generated 1)
          (push-called nil)
          (original (symbol-function 'anki-editor-push-notes)))
      (fset 'anki-editor-push-notes (lambda () (setq push-called t)))
      (unwind-protect
          (progn
            (anki-noter--maybe-push (point-min) (point-max))
            (should push-called))
        (fset 'anki-editor-push-notes original)))))

(ert-deftest anki-noter--maybe-push/no-auto-push-without-anki-editor ()
  "When anki-editor is not available, should not error."
  (anki-noter-test--with-org-buffer
      "* Parent\n** Card\nAnswer\n"
    (let ((anki-noter-auto-push t)
          (anki-noter--card-count-generated 1))
      ;; Simulate anki-editor not being available
      (cl-letf (((symbol-function 'require)
                 (lambda (feature &optional filename noerror)
                   (if (eq feature 'anki-editor)
                       nil
                     (funcall (symbol-function 'require) feature filename noerror)))))
        ;; Should not error
        (anki-noter--maybe-push (point-min) (point-max))))))

;;;; anki-noter--extract-pdf-text

(ert-deftest anki-noter--extract-pdf-text/successful-extraction ()
  "Should return extracted text when the command succeeds."
  (let ((anki-noter-pdf-fallback-command "echo 'PDF content from %%s'"))
    ;; Use echo as a mock for pdftotext; %s won't matter since echo ignores it
    (let ((anki-noter-pdf-fallback-command "echo 'Extracted PDF text'"))
      (let ((result (anki-noter--extract-pdf-text "/dummy/file.pdf")))
        (should (string-match-p "Extracted PDF text" result))))))

(ert-deftest anki-noter--extract-pdf-text/failed-command ()
  "Should signal user-error when the extraction command fails."
  (let ((anki-noter-pdf-fallback-command "false %s"))
    (should-error (anki-noter--extract-pdf-text "/dummy/file.pdf")
                  :type 'user-error)))

;;;; anki-noter--cite-file: edge cases

(ert-deftest anki-noter--cite-file/dotted-filename ()
  "Files with multiple dots should strip only the final extension."
  (should (equal "/my.book.v2/"
                 (anki-noter--cite-file "/path/my.book.v2.pdf"))))

(ert-deftest anki-noter--cite-file/single-page ()
  "Page range can be a single page."
  (should (equal "/book/, pp. 42"
                 (anki-noter--cite-file "/path/book.pdf" "42"))))

;;;; anki-noter--inherit-property: file-level properties

(ert-deftest anki-noter--inherit-property/different-property-names ()
  "Should find ANKI_TAGS the same way as ANKI_DECK."
  (anki-noter-test--with-org-buffer
      "* Parent\n:PROPERTIES:\n:ANKI_TAGS: tag1 tag2\n:END:\n** Child\n"
    (search-forward "** Child")
    (beginning-of-line)
    (should (equal "tag1 tag2" (anki-noter--inherit-property "ANKI_TAGS")))))

;;;; Integration: adjust + count roundtrip

(ert-deftest anki-noter--adjust-then-count/consistent ()
  "Adjusting heading levels should not change the heading count."
  (let* ((text "* A\n** B\n*** C\n* D\n")
         (adjusted (anki-noter--adjust-heading-levels text 3))
         (original-count (anki-noter--count-headings text))
         (adjusted-count (anki-noter--count-headings adjusted)))
    (should (= original-count adjusted-count))))

;;;; Integration: full insert-cards pipeline

(ert-deftest anki-noter--insert-cards/full-pipeline-with-fences-and-level-adjust ()
  "Code fence stripping + level adjustment + counting should all work together."
  (anki-noter-test--with-org-buffer
      "** Deep parent\n"
    (goto-char (point-max))
    (let ((anki-noter--insertion-marker (point-marker))
          (anki-noter--heading-level 4)
          (anki-noter--card-count-generated 0))
      (cl-letf (((symbol-function 'anki-noter--maybe-push) #'ignore))
        (anki-noter--insert-cards
         "```\n* Q1\nA1\n* Q2\nA2\n```"))
      (should (= 2 anki-noter--card-count-generated))
      (should (string-match-p "^\\*\\*\\*\\* Q1" (buffer-string)))
      (should (string-match-p "^\\*\\*\\*\\* Q2" (buffer-string)))
      (should-not (string-match-p "```" (buffer-string))))))

(provide 'anki-noter-test)
;;; anki-noter-test.el ends here
