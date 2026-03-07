EMACS ?= emacs

# Adjust these paths to your local package locations
GPTEL_DIR ?= $(HOME)/.emacs.d/elpaca/builds/gptel
ANKI_EDITOR_DIR ?= $(HOME)/.emacs.d/elpaca/builds/anki-editor
COMPAT_DIR ?= $(HOME)/.emacs.d/elpaca/builds/compat
TRANSIENT_DIR ?= $(HOME)/.emacs.d/elpaca/builds/transient
COND_LET_DIR ?= $(HOME)/.emacs.d/elpaca/builds/cond-let
SEQ_DIR ?= $(HOME)/.emacs.d/elpaca/builds/seq

LOAD_PATH = -L . -L test -L $(GPTEL_DIR) -L $(ANKI_EDITOR_DIR) -L $(COMPAT_DIR) -L $(TRANSIENT_DIR) -L $(COND_LET_DIR) -L $(SEQ_DIR)

.PHONY: test compile clean

test:
	$(EMACS) --batch $(LOAD_PATH) \
		--eval "(require 'ert)" --eval "(require 'cl-lib)" \
		-l test/anki-noter-prompts-test.el \
		-l test/anki-noter-test.el \
		--eval "(ert-run-tests-batch-and-exit)"

compile:
	$(EMACS) --batch $(LOAD_PATH) \
		--eval "(setq byte-compile-error-on-warn t)" \
		-f batch-byte-compile anki-noter-prompts.el anki-noter.el

clean:
	rm -f *.elc
