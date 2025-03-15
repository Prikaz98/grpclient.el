;;; grpclient-mode.el --- Description -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2025 Ivan Prikaznov
;;
;; Author: Ivan Prikaznov <prikaznov555@gmail.com>
;; Maintainer: Ivan Prikaznov <prikaznov555@gmail.com>
;;
;; This file is not part of GNU Emacs.
;;
;;; Code:

(defvar grpclient-mode-hook nil)


(defvar grpclient-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-v") #'grpclient-send-current)
    (define-key map (kbd "C-c C-u") #'grpclient-copy-grpcurl-to-clipboard)
    (define-key map (kbd "C-c C-l") #'grpclient-describe)
    (define-key map (kbd "<tab>") #'grpclient-toggle-pretty-body)
    map)
  "Keymap of grpclient major mode.")


(defface grpclient-service-face
  '((t (:inherit font-lock-variable-name-face)))
  "Face for HTTP method."
  :group 'grpclient-faces)


(defface grpclient-url-face
  '((t (:inherit font-lock-function-name-face)))
  "Face for variable value (Emacs lisp)."
  :group 'grpclient-faces)


(defface grpclient-proto-face
  '((t (:inherit font-lock-type-face)))
  "Face for variable value (Emacs lisp)."
  :group 'grpclient-faces)


(defface grpclient-var-name-face
  '((t (:inherit font-lock-keyword-face)))
  "Face for variable value (Emacs lisp)."
  :group 'grpclient-faces)


(defface grpclient-var-value-face
  '((t (:inherit font-lock-string-face)))
  "Face for variable value (Emacs lisp)."
  :group 'grpclient-faces)


(defconst grpclient-mode-font-lock-keywords
  (list
   (list "\\(GRPC\\) \\([^\s\n\r]+\\) \\(.+\\)$"
         '(1 'grpclient-var-name-face)
         '(2 'grpclient-url-face)
         '(3 'grpclient-proto-face))
   (list "\\(^:[^\s\n]+\\)=\\([^\s\n]+\\)$"
         '(1 'grpclient-var-name-face)
         '(2 'grpclient-var-value-face))
   (list "^\\(>>\\)"
         '(1 'grpclient-var-value-face)))
  "Minimal highlighting grpclient entities.")


(defconst grpclient-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\# "<" table)
    (modify-syntax-entry ?\n ">#" table)
    table))


;;TODO: fix, it is not working now
;;;###autoload
(define-derived-mode grpclient-mode fundamental-mode "GRPClient"
  "Major mode for editing grpc buffer."
  (set (make-local-variable 'comment-start) "# ")
  (set (make-local-variable 'comment-start-skip) "# *")
  (set (make-local-variable 'comment-column) 48)

  (use-local-map grpclient-mode-map)
  (set (make-local-variable 'font-lock-defaults) '(grpclient-mode-font-lock-keywords))
  (run-hooks 'grpclient-mode-hook))


(provide 'grpclient-mode)

;;grpclient-mode.el ends here
