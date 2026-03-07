;;; anki-noter-prompts.el --- Prompt templates for anki-noter -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Pablo Stafforini

;; Author: Pablo Stafforini

;; This file is part of anki-noter.

;;; Commentary:

;; Prompt templates and assembly logic for generating Anki flashcards via LLM.

;;; Code:

;;;; Customization

(defcustom anki-noter-prompt-templates
  '(("general" . "You are generating flashcards from non-fiction material. Focus on extracting key facts, definitions, important relationships, cause-effect pairs, and notable claims. Each card should capture one atomic piece of knowledge that is worth remembering long-term.")
    ("language" . "You are generating flashcards for language learning. Focus on vocabulary words, idiomatic expressions, grammar rules, and usage examples. When the output language differs from the source language, create bilingual cards with the target language on the front and the source language context or translation on the back.")
    ("programming" . "You are generating flashcards about programming and computer science. Focus on concepts, API facts, code behavior, algorithm properties, and design patterns. Cards should test understanding, not just recall. Avoid cards that simply ask for definitions — instead, ask about behavior, trade-offs, or when to use something."))
  "Named prompt templates for card generation.
Each entry is a cons cell of (NAME . PROMPT-STRING)."
  :type '(alist :key-type string :value-type string)
  :group 'anki-noter)

;;;; Base prompt

(defun anki-noter-prompts--base (deck tags card-count language cite-source
                                       existing-cards topic)
  "Build the base system prompt.
DECK is the Anki deck name. TAGS is a space-separated tag string.
CARD-COUNT is the target number of cards, or nil.
LANGUAGE is the output language, or nil.
CITE-SOURCE is the source citation string.
EXISTING-CARDS is a list of front-text strings of already-generated cards.
TOPIC is an optional topic focus string."
  (let ((parts '()))
    (push "You are an expert at creating high-quality Anki flashcards optimized for spaced repetition." parts)
    (push "\n\n## Output format\n" parts)
    (push "Output ONLY org-mode headings in the following format, with no other text before or after:\n" parts)
    (push (format "```\n*** Card front text (the question)\n:PROPERTIES:\n:ANKI_FORMAT: %s\n:ANKI_DECK: %s\n:ANKI_NOTE_TYPE: Basic\n:ANKI_TAGS: %s\n:END:\n\nCard back text (the answer)\n```\n"
                  (or (bound-and-true-p anki-noter-anki-format) "nil")
                  deck
                  tags)
           parts)
    (push "Important format rules:" parts)
    (push "\n- Each card is a separate org heading at the *** level (three stars)." parts)
    (push "\n- The heading text IS the front of the card (the question)." parts)
    (push "\n- The body text after the property drawer IS the back of the card (the answer)." parts)
    (push "\n- Do NOT include ANKI_NOTE_ID or ID properties." parts)
    (push "\n- Do NOT wrap output in a code block. Output raw org-mode text only." parts)
    (push "\n- You may suggest additional tags relevant to each card's content by adding them to the ANKI_TAGS property (space-separated, appended to the base tags provided).\n" parts)

    (push "\n## Card quality guidelines\n" parts)
    (push "- One concept per card (atomic cards)." parts)
    (push "\n- Clear, unambiguous questions." parts)
    (push "\n- Concise answers." parts)
    (push "\n- Avoid generic \"What is X?\" questions when a more specific question works." parts)
    (push "\n- Test understanding, not just recall when possible.\n" parts)

    (when cite-source
      (push (format "\n## Source citation\n\nAppend the following citation to the end of each card's back text, as a separate paragraph:\n\n%s\n"
                    (format (or (bound-and-true-p anki-noter-cite-format) "Source: %s")
                            cite-source))
            parts))

    (when card-count
      (push (format "\n## Card count\n\nGenerate approximately %d cards.\n" card-count) parts))

    (when language
      (push (format "\n## Language\n\nGenerate all card text in %s, regardless of the source material's language.\n" language) parts))

    (when topic
      (push (format "\n## Topic focus\n\nFocus only on content related to: %s. Ignore material not relevant to this topic.\n" topic) parts))

    (when existing-cards
      (push "\n## Already generated cards — do not duplicate\n\nThe following cards have already been generated from this source. Do NOT create cards that duplicate or substantially overlap with any of these:\n" parts)
      (dolist (card existing-cards)
        (push (format "\n- %s" card) parts))
      (push "\n" parts))

    (apply #'concat (nreverse parts))))

;;;; Prompt assembly

(defun anki-noter-prompts-build (template-name deck tags &rest kwargs)
  "Build the full system prompt.
TEMPLATE-NAME is the name of the template to use.
DECK is the Anki deck string. TAGS is the tags string.
KWARGS is a plist with optional keys :card-count, :language,
:cite-source, :existing-cards, :topic."
  (let* ((template (or (cdr (assoc template-name anki-noter-prompt-templates))
                       (error "Unknown template: %s" template-name)))
         (card-count (plist-get kwargs :card-count))
         (language (plist-get kwargs :language))
         (cite-source (plist-get kwargs :cite-source))
         (existing-cards (plist-get kwargs :existing-cards))
         (topic (plist-get kwargs :topic))
         (base (anki-noter-prompts--base deck tags card-count language
                                         cite-source existing-cards topic)))
    (concat base "\n## Template instructions\n\n" template)))

(provide 'anki-noter-prompts)
;;; anki-noter-prompts.el ends here
