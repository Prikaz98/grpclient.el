EMACS ?= emacs
BATCH = $(EMACS) -Q --batch -L .
TEST_UNIT   = tests/grpclient-completion-test.el
TEST_INTEG  = tests/grpclient-completion-integration-test.el

.PHONY: test test-unit test-integration clean

test: test-unit test-integration

test-unit:
	$(BATCH) -l $(TEST_UNIT) -f ert-run-tests-batch-and-exit

test-integration:
	$(BATCH) -l $(TEST_INTEG) -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc tests/*.elc
