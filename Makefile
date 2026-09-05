# Spellless
#
#   make            rebuild everything that is generated
#   make test       run the test suite
#   make bench      accuracy and latency
#   make install    deploy into the detected Rime user directory
#
# LUA can be overridden:  make test LUA=lua5.4

PYTHON ?= python3
LUA    ?= lua

GENERATED := generated/spellless.words generated/spellless.weights \
             generated/spellless.alpha generated/spellless.skel \
             generated/spellless.forms

.PHONY: all dict indexes testset test bench naive tune install uninstall dry-run clean

all: dict indexes testset

dict:
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

install:
	$(PYTHON) scripts/install.py

dry-run:
	$(PYTHON) scripts/install.py --dry-run

uninstall:
	$(PYTHON) scripts/install.py --uninstall

clean:
	rm -f $(GENERATED) generated/spellless.build.json
