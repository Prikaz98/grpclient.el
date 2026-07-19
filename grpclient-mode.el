;;; grpclient-mode.el --- Description -*- lexical-binding: t; -*-

;; Author: Ivan Prikaznov <prikaznov555@gmail.com>
;; Maintainer: Ivan Prikaznov <prikaznov555@gmail.com>
;; Created: 14 Mar 2025
;; Keywords: grpc grpcurl tools
;; Version: 0.1.0

;; Copyright (C) 2026 Ivan Prikaznov

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This is tool to manually explore and test GRPC Services based on
;; https://github.com/fullstorydev/grpcurl project. Runs queries for a
;; plain-text query sheet, displays results in separated buffer.

;;; Code:

(defvar grpclient-mode-hook nil)


(defvar grpclient-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-v") #'grpclient-send-current)
    (define-key map (kbd "C-c C-u") #'grpclient-copy-grpcurl-to-clipboard)
    (define-key map (kbd "C-c C-l") #'grpclient-describe)
    (define-key map (kbd "C-c C-c") #'grpclient-complete)
    (define-key map (kbd "<tab>") #'grpclient-toggle-pretty-body)
    map)
  "Keymap of grpclient major mode.")


(defface grpclient-service-face
  '((t (:inherit font-lock-variable-name-face)))
  "Face for HTTP method."
  :group 'grpclient-faces)


(defface grpclient-url-face
  '((t (:inherit font-lock-function-name-face)))
  "Face for variable value (Emacs Lisp)."
  :group 'grpclient-faces)


(defface grpclient-proto-face
  '((t (:inherit font-lock-type-face)))
  "Face for variable value (Emacs Lisp)."
  :group 'grpclient-faces)


(defface grpclient-var-name-face
  '((t (:inherit font-lock-keyword-face)))
  "Face for variable value (Emacs Lisp)."
  :group 'grpclient-faces)


(defface grpclient-var-value-face
  '((t (:inherit font-lock-string-face)))
  "Face for variable value (Emacs Lisp)."
  :group 'grpclient-faces)


(defconst grpclient-mode-font-lock-keywords
  (list
   (list "\\(GRPC\\) \\([^\s\n\r]+\\) \\(.+\\)$"
         '(1 'grpclient-var-name-face)
         '(2 'grpclient-url-face)
         '(3 'grpclient-proto-face))
   (list "\\(^:[^\s\n]+\\)=\\([^\n]+\\)$"
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

(provide 'grpclient-mode)

;;; grpclient-mode.el ends here
