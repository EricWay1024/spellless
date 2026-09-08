# Spellless
#
#   make            rebuild everything that is generated
#   make test       run the test suite
#   make bench      accuracy and latency
#   make release VERSION=0.1.0   build the release archive into dist/
#   make install    deploy into the detected Rime user directory
#
# LUA can be overridden:  make test LUA=lua5.4

PYTHON ?= python3
LUA    ?= lua

GENERATED := generated/spellless.words generated/spellless.weights \
             generated/spellless.alpha generated/spellless.skel \
             generated/spellless.forms generated/spellless.variants

.PHONY: all variants dict indexes testset test bench naive tune icon install uninstall dry-run release clean

all: dict indexes testset

# The variant groups come from VarCon and feed the dictionary build, which
# levels each group's frequency and fills in members the corpus is missing.
variants:
	$(PYTHON) scripts/build_variants.py

dict: variants
	$(PYTHON) scripts/build_dictionary.py

indexes: dict
	$(PYTHON) scripts/build_indexes.py

testset: indexes
	$(PYTHON) scripts/make_testset.py

test:
	$(LUA) tests/run.lua
	$(PYTHON) tests/test_install.py

bench:
	$(LUA) bench/evaluate.lua

naive:
	$(LUA) bench/naive.lua

tune:
	$(LUA) bench/tune.lua 2

# The .ico is committed, so this is only run when the drawing changes.
icon:
	$(PYTHON) scripts/make_icon.py

# The schema-only archive, which runs on Weasel, Squirrel and the Linux
# frontends alike.  The bundled Windows installer is built in the fork's own
# tree; see docs/RELEASING.md.  VERSION is required, and the tree must be clean.
release: all test
	$(PYTHON) scripts/package.py --version $(VERSION)

install:
	$(PYTHON) scripts/install.py

dry-run:
	$(PYTHON) scripts/install.py --dry-run

uninstall:
	$(PYTHON) scripts/install.py --uninstall

clean:
	rm -f $(GENERATED) generated/spellless.build.json
