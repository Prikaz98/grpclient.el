;;; run-tests.el --- Load and run all grpclient tests  -*- lexical-binding: t; -*-

;; Usage:  emacs -Q --batch --script run-tests.el
;;     or  M-x eval-buffer RET  inside Emacs

(add-to-list 'load-path default-directory)
(mapc #'load
      '("tests/grpclient-completion-test"
        "tests/grpclient-completion-integration-test"))
(ert-run-tests-batch-and-exit)
