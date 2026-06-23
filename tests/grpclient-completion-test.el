;;; grpclient-completion-test.el --- Tests for grpclient-completion  -*- lexical-binding: t; -*-

(require 'ert)
(require 'grpclient-completion)

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defvar grpclient-test-methods
  (let ((tpl1 '(("greeting" . "") ("name" . "")))
        (typ1 '(("greeting" . "string") ("name" . "string")))
        (tpl2 '(("fString" . "") ("fInt32" . 0) ("fBool" . :json-false)))
        (typ2 '(("fString" . "string") ("fInt32" . "int32") ("fBool" . "bool"))))
    `(("methods" .
       ,(vector
         (vector "hello.HelloService/SayHello" "hello.HelloService.SayHelloRequest" tpl1 typ1)
         (vector "hello.HelloService/SayHelloStream" "hello.HelloService.SayHelloRequest" tpl1 typ1)
         (vector "grpcbin.GRPCBin/DummyServerStream" "grpcbin.GRPCBin.DummyServerStreamRequest" nil nil)
         (vector "grpcbin.GRPCBin/DummyUnary" "grpcbin.GRPCBin.DummyUnaryRequest" tpl2 typ2))))))

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
;; grpclient-complete command
;; ---------------------------------------------------------------------------

(ert-deftest grpclient-complete-inserts-request ()
  "grpclient-complete inserts GRPC line, body, and end comment."
  (with-mock-data grpclient-test-methods
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt candidates &rest _)
                 (car candidates))))
      (let ((grpclient-completion-show-types nil))
        (grpclient-complete)
        (let ((text (buffer-string)))
          (should (string-match "# Call SayHello" text))
          (should (string-match "GRPC :address hello.HelloService/SayHello" text))
          (should (string-match "greeting" text))
          (should (string-match "name" text))
          (should (string-match "# end SayHello" text)))))))

(ert-deftest grpclient-complete-no-data-errors ()
  "When no reflection data is available, signal user-error."
  (with-temp-buffer
    (grpclient-mode)
    (insert ":address=test:9000\n")
    (cl-letf (((symbol-function 'grpclient--completion-get-data)
               (lambda (_server) `(("methods" . [])))))
      (should-error (grpclient-complete) :type 'user-error))))

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
     '(("field1" . "") ("field2" . ""))
     '(("field1" . "string") ("field2" . "int32")))
    (let ((text (buffer-string)))
      (should (string-match "# Call Method" text))
      (should (string-match "field1" text))
      (should (string-match "field2" text))
      (should (string-match "# end Method" text)))))

(ert-deftest insert-complete-without-template ()
  (with-temp-buffer
    (grpclient-mode)
    (insert "GRPC test:9000 pkg.Svc/Method")
    (goto-char (point-max))
    (grpclient--completion-insert-complete
     "test:9000" "pkg.Svc/Method" nil)
    (let ((text (buffer-string)))
      (should (string-match "# Call Method" text))
      (should (string-match "{}" text))
      (should (string-match "# end Method" text)))))

(ert-deftest insert-complete-shows-types ()
  "With show-types on, field lines have // type annotations."
  (with-temp-buffer
    (grpclient-mode)
    (insert "GRPC test:9000 pkg.Svc/Method")
    (goto-char (point-max))
    (let ((grpclient-completion-show-types t))
      (grpclient--completion-insert-complete
       "test:9000" "pkg.Svc/Method"
       '(("field" . "") ("count" . 0))
       '(("field" . "string") ("count" . "int32"))))
    (let ((text (buffer-string)))
      (should (string-match "// string" text))
      (should (string-match "// int32" text)))))

(ert-deftest insert-complete-hides-types ()
  "With show-types nil, no type annotations."
  (with-temp-buffer
    (grpclient-mode)
    (insert "GRPC test:9000 pkg.Svc/Method")
    (goto-char (point-max))
    (let ((grpclient-completion-show-types nil))
      (grpclient--completion-insert-complete
       "test:9000" "pkg.Svc/Method"
       '(("field" . "") ("count" . 0))
       '(("field" . "string") ("count" . "int32"))))
    (let ((text (buffer-string)))
      (should-not (string-match "// string" text))
      (should (string-match "field" text)))))

(ert-deftest insert-complete-handles-json-types ()
  (with-temp-buffer
    (grpclient-mode)
    (insert "GRPC test:9000 Method")
    (goto-char (point-max))
    (grpclient--completion-insert-complete
     "test:9000" "pkg.Svc/Method"
     '(("str" . "") ("num" . 0) ("flag" . :json-false) ("null-val" . nil)))
    (let ((text (buffer-string)))
      (should (string-match "\"str\": \"\"" text))
      (should (string-match "\"num\": 0" text))
      (should (string-match "\"flag\": false" text))
      (should (string-match "\"null-val\": null" text)))))

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

;; ---------------------------------------------------------------------------
;; Server detection
;; ---------------------------------------------------------------------------

(ert-deftest server-detected-from-address-var ()
  (with-temp-buffer
    (grpclient-mode)
    (insert ":address=grpcb.in:9000\n")
    (should (string= (grpclient--completion-server-from-buffer)
                     "grpcb.in:9000"))))

(ert-deftest server-not-found-without-address-var ()
  (with-temp-buffer
    (grpclient-mode)
    (insert ":something=else\n")
    (should-not (grpclient--completion-server-from-buffer))))

(ert-deftest server-detected-with-custom-var-name ()
  (let ((grpclient-completion-server-var ":my-server"))
    (with-temp-buffer
      (grpclient-mode)
      (insert ":my-server=custom:8080\n")
      (should (string= (grpclient--completion-server-from-buffer)
                       "custom:8080")))))

;; ---------------------------------------------------------------------------
;; In-memory cache
;; ---------------------------------------------------------------------------

(ert-deftest memory-cache-avoids-disk-read ()
  (let* ((calls 0)
         (grpclient--completion-cache (make-hash-table :test 'equal))
         (data `(("server" . "test:9000")
                 ("fetched-at" . ,(format-time-string "%Y-%m-%dT%TZ" nil t))
                 ("methods" . []))))
    (puthash "test:9000" data grpclient--completion-cache)
    (cl-letf (((symbol-function 'grpclient--completion-read-disk-cache)
               (lambda (_server) (cl-incf calls) nil))
              ((symbol-function 'grpclient--completion-fetch-all)
               (lambda (_server) (cl-incf calls) nil)))
      (should (grpclient--completion-get-data "test:9000"))
      (should (= calls 0)))))

(provide 'grpclient-completion-test)
;;; grpclient-completion-test.el ends here
