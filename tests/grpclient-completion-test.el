;;; grpclient-completion-test.el --- Tests for grpclient-completion  -*- lexical-binding: t; -*-

(require 'ert)
(require 'grpclient-completion)

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defvar grpclient-test-methods
  (let ((tpl1 '(("greeting" . "") ("name" . "")))
        (tpl2 '(("fString" . "") ("fInt32" . 0) ("fBool" . :json-false))))
    `(("methods" .
       ,(vector
         (vector "hello.HelloService/SayHello" "hello.HelloService.SayHelloRequest" tpl1)
         (vector "hello.HelloService/SayHelloStream" "hello.HelloService.SayHelloRequest" tpl1)
         (vector "grpcbin.GRPCBin/DummyServerStream" "grpcbin.GRPCBin.DummyServerStreamRequest" nil)
         (vector "grpcbin.GRPCBin/DummyUnary" "grpcbin.GRPCBin.DummyUnaryRequest" tpl2))))))

(defmacro with-mock-data (data &rest body)
  "Create a grpclient-mode buffer with :address and mock DATA."
  (declare (indent 1))
  `(with-temp-buffer
     (grpclient-mode)
     (insert ":address=test:9000\n")
     (cl-letf (((symbol-function 'grpclient--completion-get-data)
                (lambda (_server) ,data)))
       ,@body)))

(defmacro with-grpclient-cache-dir (&rest body)
  (declare (indent 0))
  `(let ((grpclient-completion-cache-dir (make-temp-file "grpc-cache-" t)))
     (unwind-protect (progn ,@body)
       (delete-directory grpclient-completion-cache-dir t nil))))

;; ---------------------------------------------------------------------------
;; Body and end-comment insertion
;; ---------------------------------------------------------------------------

(ert-deftest insert-complete-with-template ()
  (with-temp-buffer
    (grpclient-mode)
    (insert "GRPC test:9000 pkg.Svc/Method")
    (goto-char (point-max))
    (grpclient--completion-insert-complete
     "test:9000" "pkg.Svc/Method"
     '(("field1" . "") ("field2" . "")))
    (let ((text (buffer-string)))
      (should (string-match "field1" text))
      (should (string-match "field2" text)))))

(ert-deftest insert-complete-without-template ()
  (with-temp-buffer
    (grpclient-mode)
    (insert "GRPC test:9000 pkg.Svc/Method")
    (goto-char (point-max))
    (grpclient--completion-insert-complete
     "test:9000" "pkg.Svc/Method" nil)
    (let ((text (buffer-string)))
      (should (string-match "{}" text)))))

(ert-deftest insert-complete-handles-json-types ()
  (with-temp-buffer
    (grpclient-mode)
    (insert "GRPC test:9000 Method")
    (goto-char (point-max))
    (grpclient--completion-insert-complete
     "test:9000" "pkg.Svc/Method"
     '(("str" . "") ("num" . 0) ("flag" . :json-false) ("null-val" . nil) ("nested" ("value" . ""))))
    (let ((text (buffer-string)))
      (should (string-match "\"str\": \"\"" text))
      (should (string-match "\"num\": 0" text))
      (should (string-match "\"flag\": false" text))
      (should (string-match "\"null-val\": null" text))
      (should (string-match "\"nested\": { \"value\": \"\" }" text)))))

;; ---------------------------------------------------------------------------
;; Cache roundtrip
;; ---------------------------------------------------------------------------

(ert-deftest cache-write-read ()
  (with-grpclient-cache-dir
    (let ((t1 (quote (( "f1" . "")))))
      (let ((data (list (cons "server" "test:9000")
                        (cons "fetched-at"
                              (format-time-string "%Y-%m-%dT%TZ" nil t))
                        (cons "methods"
                              (vector (vector "Svc/M1" "Svc.M1Request" t1))))))
      (grpclient--completion-write-disk-cache "test:9000" data)
      (let ((read-back (grpclient--completion-read-disk-cache "test:9000")))
        (should read-back)
        (should (equal read-back data))))))

(ert-deftest cache-stale-returns-nil ()
  (with-grpclient-cache-dir
    (let ((grpclient-completion-cache-ttl 0))
      (grpclient--completion-write-disk-cache
       "test:9000" `(("server" . "test:9000")
                     ("fetched-at" . ,(format-time-string "%Y-%m-%dT%TZ" nil t))
                     ("methods" . ())))
      (should-not (grpclient--completion-read-disk-cache "test:9000")))))

(ert-deftest cache-missing-file-returns-nil ()
  (with-grpclient-cache-dir
    (should-not (grpclient--completion-read-disk-cache "nonexistent:0000"))))

(ert-deftest cache-corrupted-file-returns-nil ()
  (with-grpclient-cache-dir
    (let ((file (grpclient--completion-cache-file "bad:0000")))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert "{not json!"))
      (should-not (grpclient--completion-read-disk-cache "bad:0000")))))

(ert-deftest cache-wrong-server-key-returns-nil ()
  (with-grpclient-cache-dir
    (grpclient--completion-write-disk-cache
     "real:9000" `(("server" . "real:9000")
                   ("fetched-at" . ,(format-time-string "%Y-%m-%dT%TZ" nil t))
                   ("methods" . ())))
    (should-not (grpclient--completion-read-disk-cache "different:9000")))))


(provide 'grpclient-completion-test)
;;; grpclient-completion-test.el ends here
