;;; grpclient-completion-test.el --- Tests for grpclient-completion  -*- lexical-binding: t; -*-

(require 'ert)
(require 'grpclient-completion)

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

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
    (insert "GRPC test:9000 pkg.Svc/Method")
    (goto-char (point-max))
    (grpclient--completion-insert-complete
     "test:9000" "pkg.Svc/Method" nil)
    (let ((text (buffer-string)))
      (should (string-match "{}" text)))))

(ert-deftest insert-complete-handles-json-types ()
  (with-temp-buffer
    (insert "GRPC test:9000 Method")
    (goto-char (point-max))
    (grpclient--completion-insert-complete
     "test:9000" "pkg.Svc/Method"
     '(("str" . "") ("num" . 0) ("flag" . :json-false) ("null-val" . nil) ("nested" ("value" . ""))))
    (let ((text (buffer-string)))
      (should (string-match "\"str\":\"\"" text))
      (should (string-match "\"num\":0" text))
      (should (string-match "\"flag\":false" text))
      (should (string-match "\"null-val\":null" text))
      (should (string-match "\"nested\":{\"value\":\"\"}" text)))))

;; ---------------------------------------------------------------------------
;; Cache roundtrip
;; ---------------------------------------------------------------------------

(ert-deftest cache-write-read ()
  (with-grpclient-cache-dir
    (let ((t1 '(( "f1" . ""))))
      (let ((data `(("server" . "test:9000")
                    ("fetched-at" . ,(format-time-string "%Y-%m-%dT%TZ" nil t))
                    ("methods" . ,(vector (vector "Svc/M1" "Svc.M1Request" t1))))))
        (grpclient--completion-write-disk-cache "test:9000" data)
        (let ((read-back (grpclient--completion-read-disk-cache "test:9000")))
          (should read-back)
          (should (equal read-back data)))))))

(ert-deftest cache-stale-returns-nil ()
  (with-grpclient-cache-dir
    (let ((grpclient-completion-cache-ttl 0)
          (t1 '(( "f1" . ""))))
      (grpclient--completion-write-disk-cache
       "test:9000" `(("server" . "test:9000")
                     ("fetched-at" . ,(format-time-string "%Y-%m-%dT%TZ" nil t))
                     ("methods" . ,(vector (vector "Svc/M1" "Svc.M1Request" t1)))))
      (should-not (grpclient--completion-read-disk-cache "test:9000")))))

(ert-deftest cache-missing-file-returns-nil ()
  (with-grpclient-cache-dir
    (should-not (grpclient--completion-read-disk-cache "nonexistent:0000"))))

(ert-deftest cache-corrupted-file-returns-nil ()
  (with-grpclient-cache-dir
    (let ((file (grpclient--completion-cache-file-path "bad:0000")))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert "{not json!"))
      (should-not (grpclient--completion-read-disk-cache "bad:0000")))))

(ert-deftest cache-wrong-server-key-returns-nil ()
  (with-grpclient-cache-dir
    (let ((t1 '(( "f1" . ""))))
      (grpclient--completion-write-disk-cache
       "real:9000" `(("server" . "real:9000")
                     ("fetched-at" . ,(format-time-string "%Y-%m-%dT%TZ" nil t))
                     ("methods" . ,(vector (vector "Svc/M1" "Svc.M1Request" t1)))))
      (should-not (grpclient--completion-read-disk-cache "different:9000")))))

(provide 'grpclient-completion-test)
;;; grpclient-completion-test.el ends here
