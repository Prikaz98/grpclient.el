;;; grpclient-completion-integration-test.el --- Integration tests for grpclient-completion  -*- lexical-binding: t; -*-

;; Integration tests mock `grpclient--completion-run' to call
;; `tests/mock-grpcurl' directly by its full path.

(require 'ert)
(require 'grpclient-completion)

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defvar grpclient-test-mock-path
  (expand-file-name "mock-grpcurl"
                    (file-name-directory (or load-file-name default-directory)))
  "Absolute path to the mock-grpcurl script.")

(defmacro with-mock-grpcurl (&rest body)
  "Run BODY with `grpclient--completion-run' calling mock-grpcurl by full path."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'grpclient--completion-run)
              (lambda (fmt &rest args)
                (let* ((flags (string-join grpclient-default-flags " "))
                       (cmd (format "%s %s %s" grpclient-test-mock-path
                                    flags (apply #'format fmt args))))
                  (with-temp-buffer
                    (let ((exit (call-process shell-file-name nil t nil
                                              shell-command-switch cmd)))
                      (unless (zerop exit)
                        (error "grpcurl failed (exit %d): %s" exit cmd))
                      (split-string (buffer-string) "\n" t)))))))
     ,@body))

;; ---------------------------------------------------------------------------
;; grpcurl list — services
;; ---------------------------------------------------------------------------

(ert-deftest list-services ()
  (with-mock-grpcurl
    (should (equal (grpclient--completion-fetch-services "localhost:9000")
                   '("hello.HelloService" "grpcbin.GRPCBin")))))

(ert-deftest list-services-unknown-server ()
  (with-mock-grpcurl
    (should-not (grpclient--completion-fetch-services "unknown:0000"))))

;; ---------------------------------------------------------------------------
;; Full fetch: describe each service + msg-template for each request type
;; ---------------------------------------------------------------------------

(ert-deftest fetch-all-structure ()
  (with-mock-grpcurl
    (let* ((data (grpclient--completion-fetch-all "localhost:9000"))
           (methods (alist-get "methods" data nil nil #'equal)))
      (should data)
      (should (= (length methods) 4))

      ;; hello.HelloService/SayHello
      (let* ((entry (cl-find "hello.HelloService/SayHello" methods
                             :key (lambda (e) (aref e 0)) :test #'string=))
             (req-type (aref entry 1))
             (template (aref entry 2)))
        (should entry)
        (should (string= req-type "hello.HelloService.SayHelloRequest"))
        (should (consp template))
        (should (assoc "greeting" template))
        (should (assoc "name" template)))

      ;; hello.HelloService/SayHelloStream
      (should (cl-find "hello.HelloService/SayHelloStream" methods
                       :key (lambda (e) (aref e 0)) :test #'string=))

      ;; grpcbin.GRPCBin/DummyUnary
      (let* ((entry (cl-find "grpcbin.GRPCBin/DummyUnary" methods
                             :key (lambda (e) (aref e 0)) :test #'string=))
             (template (aref entry 2)))
        (should entry)
        (should (consp template))
        (should (assoc "fString" template))
        (should (assoc "fInt32" template))
        (should (assoc "fBool" template)))

      ;; grpcbin.GRPCBin/DummyServerStream has no template (nil)
      (let* ((entry (cl-find "grpcbin.GRPCBin/DummyServerStream" methods
                             :key (lambda (e) (aref e 0)) :test #'string=))
             (template (aref entry 2)))
        (should entry)
        (should-not template)))))

;; ---------------------------------------------------------------------------
;; Unknown method returns nil template
;; ---------------------------------------------------------------------------

(ert-deftest msg-template-unknown ()
  (with-mock-grpcurl
    (let ((data (grpclient--completion-fetch-all "unknown:0000")))
      (should data)
      (should (zerop (length (alist-get "methods" data nil nil #'equal)))))))

(provide 'grpclient-completion-integration-test)
;;; grpclient-completion-integration-test.el ends here
