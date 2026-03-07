;;; anki-noter-prompts-test.el --- Tests for anki-noter-prompts.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for prompt template lookup, base prompt assembly, and full prompt
;; construction in anki-noter-prompts.el.

;;; Code:

(require 'ert)
(require 'anki-noter-prompts)

;;;; anki-noter-prompts-build

(ert-deftest anki-noter-prompts-build/unknown-template-signals-error ()
  "An unknown template name should signal an error."
  (should-error (anki-noter-prompts-build "nonexistent" "Deck" "tag1")
                :type 'error))

(ert-deftest anki-noter-prompts-build/general-template-includes-template-text ()
  "The general template text should appear in the assembled prompt."
  (let ((result (anki-noter-prompts-build "general" "MyDeck" "tag1")))
    (should (string-match-p "non-fiction material" result))))

(ert-deftest anki-noter-prompts-build/includes-deck-and-tags ()
  "The deck and tags should appear in the output format section."
  (let ((result (anki-noter-prompts-build "general" "History::WW2" "history war")))
    (should (string-match-p "History::WW2" result))
    (should (string-match-p "history war" result))))

(ert-deftest anki-noter-prompts-build/includes-template-instructions-header ()
  "The assembled prompt should contain the template instructions section."
  (let ((result (anki-noter-prompts-build "general" "Deck" "tags")))
    (should (string-match-p "## Template instructions" result))))

(ert-deftest anki-noter-prompts-build/language-template ()
  "The language template should include language-learning keywords."
  (let ((result (anki-noter-prompts-build "language" "Vocab" "spanish")))
    (should (string-match-p "language learning" result))
    (should (string-match-p "vocabulary" result))))

(ert-deftest anki-noter-prompts-build/programming-template ()
  "The programming template should include programming-specific guidance."
  (let ((result (anki-noter-prompts-build "programming" "CS" "algorithms")))
    (should (string-match-p "programming" result))
    (should (string-match-p "design patterns" result))))

(ert-deftest anki-noter-prompts-build/custom-template ()
  "A user-defined template should work when added to the alist."
  (let ((anki-noter-prompt-templates
         (cons '("custom" . "Custom template text here.")
               anki-noter-prompt-templates)))
    (let ((result (anki-noter-prompts-build "custom" "Deck" "tags")))
      (should (string-match-p "Custom template text here" result)))))

;;;; anki-noter-prompts--base: optional sections

(ert-deftest anki-noter-prompts--base/no-optional-sections-when-nil ()
  "When all optional args are nil, optional sections should not appear."
  (let ((result (anki-noter-prompts--base "Deck" "tags" nil nil nil nil nil)))
    (should-not (string-match-p "## Card count" result))
    (should-not (string-match-p "## Language" result))
    (should-not (string-match-p "## Topic focus" result))
    (should-not (string-match-p "Already generated cards" result))
    (should-not (string-match-p "## Source citation" result))))

(ert-deftest anki-noter-prompts--base/card-count-section ()
  "When card-count is provided, the card count section should appear."
  (let ((result (anki-noter-prompts--base "Deck" "tags" 15 nil nil nil nil)))
    (should (string-match-p "## Card count" result))
    (should (string-match-p "15" result))))

(ert-deftest anki-noter-prompts--base/language-section ()
  "When language is provided, the language section should appear."
  (let ((result (anki-noter-prompts--base "Deck" "tags" nil "Spanish" nil nil nil)))
    (should (string-match-p "## Language" result))
    (should (string-match-p "Spanish" result))))

(ert-deftest anki-noter-prompts--base/cite-source-section ()
  "When cite-source is provided, the citation section should appear."
  (let ((result (anki-noter-prompts--base "Deck" "tags" nil nil "myfile.org" nil nil)))
    (should (string-match-p "## Source citation" result))
    (should (string-match-p "myfile.org" result))))

(ert-deftest anki-noter-prompts--base/cite-source-uses-cite-format ()
  "The citation should use `anki-noter-cite-format`."
  (let ((anki-noter-cite-format "Ref: %s"))
    (let ((result (anki-noter-prompts--base "Deck" "tags" nil nil "chapter.org" nil nil)))
      (should (string-match-p "Ref: chapter.org" result)))))

(ert-deftest anki-noter-prompts--base/topic-section ()
  "When topic is provided, the topic focus section should appear."
  (let ((result (anki-noter-prompts--base "Deck" "tags" nil nil nil nil "neural networks")))
    (should (string-match-p "## Topic focus" result))
    (should (string-match-p "neural networks" result))))

(ert-deftest anki-noter-prompts--base/existing-cards-section ()
  "When existing-cards is provided, the deduplication section should appear."
  (let ((result (anki-noter-prompts--base "Deck" "tags" nil nil nil
                                          '("What is X?" "Who invented Y?") nil)))
    (should (string-match-p "Already generated cards" result))
    (should (string-match-p "What is X?" result))
    (should (string-match-p "Who invented Y?" result))))

(ert-deftest anki-noter-prompts--base/all-optional-sections-together ()
  "All optional sections should appear when all args are provided."
  (let ((result (anki-noter-prompts--base
                 "Deck" "tags" 10 "French" "book.pdf"
                 '("Card A" "Card B") "philosophy")))
    (should (string-match-p "## Card count" result))
    (should (string-match-p "## Language" result))
    (should (string-match-p "## Source citation" result))
    (should (string-match-p "## Topic focus" result))
    (should (string-match-p "Already generated cards" result))))

(ert-deftest anki-noter-prompts--base/always-includes-base-sections ()
  "The base prompt should always include output format and quality guidelines."
  (let ((result (anki-noter-prompts--base "Deck" "tags" nil nil nil nil nil)))
    (should (string-match-p "## Output format" result))
    (should (string-match-p "## Card quality guidelines" result))
    (should (string-match-p "expert at creating" result))))

(ert-deftest anki-noter-prompts--base/anki-format-in-output ()
  "The ANKI_FORMAT value should appear in the output format example."
  (let ((anki-noter-anki-format "html"))
    (let ((result (anki-noter-prompts--base "Deck" "tags" nil nil nil nil nil)))
      (should (string-match-p "ANKI_FORMAT: html" result)))))

(ert-deftest anki-noter-prompts--base/anki-format-nil ()
  "When ANKI_FORMAT is nil, the example should show nil."
  (let ((anki-noter-anki-format nil))
    (let ((result (anki-noter-prompts--base "Deck" "tags" nil nil nil nil nil)))
      (should (string-match-p "ANKI_FORMAT: nil" result)))))

(ert-deftest anki-noter-prompts--base/note-type-always-basic ()
  "The output format should always specify Basic note type."
  (let ((result (anki-noter-prompts--base "Deck" "tags" nil nil nil nil nil)))
    (should (string-match-p "ANKI_NOTE_TYPE: Basic" result))))

;;;; Prompt assembly via keyword args

(ert-deftest anki-noter-prompts-build/passes-kwargs-to-base ()
  "Keyword arguments should be threaded through to the base prompt."
  (let ((result (anki-noter-prompts-build
                 "general" "Deck" "tags"
                 :card-count 5
                 :language "German"
                 :cite-source "source.txt"
                 :topic "ethics"
                 :existing-cards '("Existing card"))))
    (should (string-match-p "5" result))
    (should (string-match-p "German" result))
    (should (string-match-p "source.txt" result))
    (should (string-match-p "ethics" result))
    (should (string-match-p "Existing card" result))))

;;;; Section ordering

(ert-deftest anki-noter-prompts-build/base-before-template ()
  "Base prompt sections should appear before template instructions."
  (let ((result (anki-noter-prompts-build "general" "Deck" "tags")))
    (let ((base-pos (string-match "## Output format" result))
          (template-pos (string-match "## Template instructions" result)))
      (should base-pos)
      (should template-pos)
      (should (< base-pos template-pos)))))

(ert-deftest anki-noter-prompts-build/quality-before-template ()
  "Card quality guidelines should appear before template instructions."
  (let ((result (anki-noter-prompts-build "general" "Deck" "tags")))
    (let ((quality-pos (string-match "## Card quality" result))
          (template-pos (string-match "## Template instructions" result)))
      (should quality-pos)
      (should template-pos)
      (should (< quality-pos template-pos)))))

;;;; Edge cases

(ert-deftest anki-noter-prompts--base/empty-existing-cards-list ()
  "An empty existing-cards list should not add the deduplication section."
  (let ((result (anki-noter-prompts--base "Deck" "tags" nil nil nil '() nil)))
    (should-not (string-match-p "Already generated cards" result))))

(ert-deftest anki-noter-prompts--base/special-chars-in-deck ()
  "Deck names with :: separators should appear verbatim in the prompt."
  (let ((result (anki-noter-prompts--base "Main::Sub::Deep" "tags" nil nil nil nil nil)))
    (should (string-match-p "Main::Sub::Deep" result))))

(ert-deftest anki-noter-prompts--base/special-chars-in-tags ()
  "Multiple space-separated tags should appear in the prompt."
  (let ((result (anki-noter-prompts--base "Deck" "tag1 tag2 tag3" nil nil nil nil nil)))
    (should (string-match-p "tag1 tag2 tag3" result))))

(ert-deftest anki-noter-prompts--base/large-card-count ()
  "A large card count should appear correctly."
  (let ((result (anki-noter-prompts--base "Deck" "tags" 100 nil nil nil nil)))
    (should (string-match-p "100" result))))

(ert-deftest anki-noter-prompts--base/existing-cards-preserves-order ()
  "Existing cards should appear in the order given."
  (let ((result (anki-noter-prompts--base "Deck" "tags" nil nil nil
                                          '("First card" "Second card" "Third card") nil)))
    (let ((pos1 (string-match "First card" result))
          (pos2 (string-match "Second card" result))
          (pos3 (string-match "Third card" result)))
      (should pos1)
      (should pos2)
      (should pos3)
      (should (< pos1 pos2))
      (should (< pos2 pos3)))))

(ert-deftest anki-noter-prompts--base/format-rules-present ()
  "Important format rules should always be in the prompt."
  (let ((result (anki-noter-prompts--base "Deck" "tags" nil nil nil nil nil)))
    (should (string-match-p "ANKI_NOTE_ID" result))
    (should (string-match-p "Do NOT wrap output in a code block" result))
    (should (string-match-p "three stars" result))))

(provide 'anki-noter-prompts-test)
;;; anki-noter-prompts-test.el ends here
