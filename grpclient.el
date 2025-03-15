;;; grpclient.el --- Description -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2025 Ivan Prikaznov
;;
;; Author: Ivan Prikaznov <prikaznov555@gmail.com>
;; Maintainer: Ivan Prikaznov <prikaznov555@gmail.com>
;; Created: 14 Mar 2025
;; Keywords: grpc grpcurl

;;
;; This file is not part of GNU Emacs.
;;

;;; Commentary:
;; This is tool to manually explore and test GRPC Services based on
;; https://github.com/fullstorydev/grpcurl project. Runs queries for a
;; plain-text query sheet, displays results in separated buffer.

;;; TODO:
;; - hooks
;; - print message to install grpcurl if it doesn't exists

;;; Code:
;;
(require 'json)
(eval-when-compile
  (if (version< emacs-version "26")
      (require 'cl)
    (require 'cl-lib)))
(require 'grpclient-mode)

(defcustom grpclient-default-flags '("-plaintext")
  "Default flags that append in every query."
  :type 'list
  :group 'grpclient)

(defconst grpclient-flags-block-start-regexp "^:flags=<<")
(defconst grpclient-flags-block-end-regexp "^>>")
(defconst grpclient-comment-separator "#")
(defconst grpclient-comment-start-regexp (concat "^" grpclient-comment-separator))
(defconst grpclient-comment-not-regexp (concat "^[^" grpclient-comment-separator "]"))
(defconst grpclient-empty-line-regexp "^\\s-*$")

;;stolen from 's beautiful library https://github.com/magnars/s.el
(defun grpclient--replace-all (replacements s)
  "REPLACEMENTS is a list of cons-cells. Each `car` is replaced with `cdr` in S."
  (let ((case-fold-search nil))
   (replace-regexp-in-string (regexp-opt (mapcar 'car replacements))
                             (lambda (it) (cdr (assoc-string it replacements)))
                             s t t)))

(defun grpclient--non-nil (list)
  "Return a copy of LIST with all nil items removed."
  (seq-filter 'identity list))


(defun grpclient--trim-to-nil (str)
  "If trimmed string is empty return nil else trimmed string"
  (let ((trimmed (string-trim str)))
    (unless (string-empty-p trimmed) trimmed)))


(defun grpclient--current-min ()
  (save-excursion
    (beginning-of-line)
    (if (looking-at grpclient-comment-start-regexp)
        (if (re-search-forward grpclient-comment-not-regexp (point-max) t)
            (point-at-bol) (point-max))
      (if (re-search-backward grpclient-comment-start-regexp (point-min) t)
          (point-at-bol 2)
        (point-min)))))


(defun grpclient--current-max ()
  (save-excursion
    (if (re-search-forward grpclient-comment-start-regexp (point-max) t)
        (max (- (point-at-bol) 1) 1)
      (progn (goto-char (point-max))
             (if (looking-at "^$") (- (point) 1) (point))))))


(defun grpclient--current-line ()
  (buffer-substring-no-properties
   (progn (beginning-of-line) (point))
   (progn (end-of-line) (point))))


(defun grpclient--collect-vars-before ()
  (save-excursion
    (let ((vars nil)
          (bound (point)))
      (goto-char (point-min))
      (while (search-forward-regexp "^:.+=" bound t)
        (cl-destructuring-bind (key value) (split-string (grpclient--current-line) "=")
          (setq vars (cons (cons key value) vars))))
      vars)))

(defun grpclient--find-flags (bound)
  (save-excursion
    (goto-char (point-min))
    (when (search-forward-regexp grpclient-flags-block-start-regexp bound t)
      (thread-last
        (buffer-substring-no-properties
         (point)
         (or
          (search-forward-regexp (concat ">>") bound t)
          (grpclient--current-max)))
        (replace-regexp-in-string (concat grpclient-comment-start-regexp ".+$") "")
        (replace-regexp-in-string grpclient-flags-block-end-regexp "")
        (replace-regexp-in-string "[ \r\t\n]+" " ")
        (grpclient--trim-to-nil)))))


(defun grpclient--build-command ()
  (save-excursion
    (goto-char (grpclient--current-min))
    (let* ((url-proto-method (cdr (string-split (grpclient--current-line) " ")))
           (url (cl-first url-proto-method))
           (vars (grpclient--collect-vars-before))
           (method (cl-second url-proto-method))
           (proto (cl-third url-proto-method))
           (cmax (grpclient--current-max))
           (flags (grpclient--find-flags (grpclient--current-min)))
           (body (string-trim (buffer-substring-no-properties (min (point) cmax) cmax)))
           (cmd-builder (list "grpcurl"
                              (when body (concat "-d '" (encode-coding-string (grpclient--replace-all vars body) 'utf-8) "'"))
                              (string-join grpclient-default-flags " ")
                              (when flags (grpclient--replace-all vars flags))
                              (when proto (concat "-proto " (grpclient--replace-all vars proto)))
                              (grpclient--replace-all vars url)
                              (if method (grpclient--replace-all vars method) ""))))
      (string-join (grpclient--non-nil cmd-builder) " "))))


(defun grpclient-pretty-current ()
  "Pretty print body of current grpclient entity."
  (interactive)
  (save-excursion
    (let ((body-start)
          (body-end))
      (when (re-search-forward "^\{\.+\}$" (grpclient--current-max) t)
        (setq body-end (point))
        (beginning-of-line)
        (setq body-start (point))
        (json-pretty-print body-start body-end)
        t))))


(defun grpclient-collaps-current ()
  "Collaps body of current grpclient entity."
  (interactive)
  (save-excursion
    (when (re-search-forward "^\{$" (grpclient--current-max) t)
      (let ((body-start)
            (body-end))
        (setq body-start (- (point) 1))
        (when (re-search-forward "^\}$" (grpclient--current-max))
          (setq body-end (point))
          (json-pretty-print body-start body-end t)
          t)))))


(defun grpclient-toggle-pretty-body ()
  "Pretty print body if it minimalized or conversely."
  (interactive)
  (or (grpclient-pretty-current)
      (grpclient-collaps-current)))


(defun grpclient-copy-grpcurl-to-clipboard ()
  "Build command and copy them into clipboard."
  (interactive)
  (let ((cmd (grpclient--build-command)))
    (kill-new cmd)
    (message cmd)))


(defun grpclient-send-current ()
  "Prepare grpcurl command and execute it asynchronously.

Entity format:
#
GRPC host:port path.Service.Method
{}
#
- Use # to set bound of the entity
- GRPC is an anchor word of the query
- {} is an body of the query.

To exactly ensure what command is built call method
`(grpclient-copy-grpcurl-to-clipboard)`"
  (interactive)
  (let ((cmd (grpclient--build-command)))
    (with-temp-buffer
     (async-shell-command cmd "*GRPC Response*" "*GRPC Error*")
     (buffer-string))))


(defvar grpclient-last-url nil)


(defun grpclient-describe ()
  "Describe things."
  (interactive)
  (let* ((url (setq grpclient-last-url (read-string "Enter url: " grpclient-last-url)))
         (message (grpclient--trim-to-nil (read-string "Enter message or nothing: " (thing-at-point 'filename t))))
         (builder (list
                   "grpcurl -plaintext"
                   (when message "-msg-template")
                   url
                   "describe"
                   message))
         (cmd (string-join (grpclient--non-nil builder) " ")))
    (async-shell-command cmd
                         (string-join (grpclient--non-nil (list "*GRPC" message "Description*")) " ")
                         "*GRPC Error*")))


(provide 'grpclient)

;;grpclient.el  ends here
