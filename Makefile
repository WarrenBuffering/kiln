.PHONY: test doctor demo run

doctor:
	./bin/kiln --doctor

run:
	./bin/kiln .

demo:
	./bin/kiln --demo .

test:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v
	@for test in tests/test_*.lua; do \
		PYTHONDONTWRITEBYTECODE=1 KILN_HOME="$(CURDIR)" KILN_STATE_DIR="$(CURDIR)/.state/test" nvim --headless -u NONE -i NONE -n -c "luafile $$test" || exit $$?; \
	done
