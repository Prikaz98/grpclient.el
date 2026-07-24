;;; grpclient.el --- Grpcurl interactive builder -*- lexical-binding: t; -*-

;; Homepage: https://github.com/Prikaz98/grpclient.el

;; Author: Ivan Prikaznov <prikaznov555@gmail.com>
;;    Miloš Tepić <tepcmils@gmail.com>
;; Maintainer: Ivan Prikaznov <prikaznov555@gmail.com>
;;    Miloš Tepić <tepcmils@gmail.com>
;; Created: 14 Mar 2025
;; Keywords: grpc grpcurl tools
;; Version: 0.1.0

;; Package-Requires: ((emacs "29.1"))

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

(require 'json)
(require 'cl-lib)
(require 'grpclient-mode)
(require 'grpclient-completion)


(defcustom grpclient-default-flags '("-plaintext")
  "Default flags that append in every query."
  :type '(repeat string)
  :group 'grpclient)

(defcustom grpclient-completion-cache-dir
  (expand-file-name ".cache/grpcurl-autocomplete/" user-emacs-directory)
  "Directory for cached reflection data."
  :type 'directory
  :group 'grpclient)


(defcustom grpclient-completion-cache-ttl 86400
  "Seconds before cached reflection data is refetched (default 24 hours)."
  :type 'integer
  :group 'grpclient)


(defcustom grpclient-completion-system 'auto
  "Completion framework used for selecting gRPC methods.
When `auto', the active framework is detected from enabled minor modes.
Set to `default' to use plain `completing-read' (works with vertico,
consult, icomplete, selectrum, etc.)."
  :type '(radio
          (const :tag "Auto-detect" auto)
          (const :tag "Ido" ido)
          (const :tag "Helm" helm)
          (const :tag "Ivy" ivy)
          (const :tag "Default" default)
          (function :tag "Custom function"))
  :group 'grpclient)


(defconst grpclient-flags-block-start-regexp "^:flags=<<")
(defconst grpclient-flags-block-end-regexp "^>>")
(defconst grpclient-comment-separator "#")
(defconst grpclient-comment-start-regexp (concat "^" grpclient-comment-separator))
(defconst grpclient-comment-not-regexp (concat "^[^" grpclient-comment-separator "]"))
(defconst grpclient-empty-line-regexp "^\\s-*$")
(defconst grpclient-response-hook-regexp "^\\(->\\) +\\(.*\\)$")

(defvar grpclient-override-vars nil "Key Value pair list that override vars while building a query.")


(defun grpclient-set-var (key value)
  "Set VALUE under the KEY in `grpclient-override-vars' varaible."
  (setq grpclient-override-vars
        (cons
         (cons key value)
         (assoc-delete-all key grpclient-override-vars))))


;;stolen from 's beautiful library https://github.com/magnars/s.el
(defun grpclient--replace-all (replacements s)
  "REPLACEMENTS is a list of cons-cells. Each `car` is replaced with `cdr` in S."
  (let ((case-fold-search nil))
   (replace-regexp-in-string (regexp-opt (mapcar 'car replacements))
                             (lambda (it) (cdr (assoc-string it replacements)))
                             s t t)))


(defun grpclient--replace-vars-with-override (vars)
  "Replace defined in file VARS with `grpclient-override-vars` variable."
  (let* ((keys-to-override (mapcar #'car grpclient-override-vars)))
    (dolist (key keys-to-override)
      (setq vars (assoc-delete-all key vars)))
    (append vars grpclient-override-vars)))


(defun grpclient--non-nil (list)
  "Return a copy of LIST with all nil items removed."
  (seq-filter 'identity list))


(defun grpclient--trim-to-nil (str)
  "If trimmed STR is empty return nil else trimmed string."
  (let ((trimmed (string-trim str)))
    (unless (string-empty-p trimmed) trimmed)))


(defun grpclient--current-min ()
  "Return min point of current request entity."
  (save-excursion
    (beginning-of-line)
    (if (looking-at grpclient-comment-start-regexp)
        (if (re-search-forward grpclient-comment-not-regexp (point-max) t)
            (point-at-bol) (point-max))
      (if (re-search-backward grpclient-comment-start-regexp (point-min) t)
          (point-at-bol 2)
        (point-min)))))


(defun grpclient--current-max ()
  "Return min point of current request entity."
  (save-excursion
    (if (re-search-forward grpclient-comment-start-regexp (point-max) t)
        (max (- (point-at-bol) 1) 1)
      (progn (goto-char (point-max))
             (if (looking-at "^$") (- (point) 1) (point))))))


(defun grpclient--current-line ()
  "Return current line."
  (buffer-substring-no-properties
   (progn (beginning-of-line) (point))
   (progn (end-of-line) (point))))


(defun grpclient--collect-vars-before ()
  "Return list of vars defined before the current query."
  (save-excursion
    (let ((vars nil)
          (bound (point))
          (sexp? nil))
      (goto-char (point-min))
      (while (search-forward-regexp "^:.+=" bound t)
        (setq sexp? (looking-at "\(.+\)$"))
        (cl-destructuring-bind (key value) (split-string (grpclient--current-line) "=")
          (when sexp?
              (setq value (eval-expression (read value))))
          (setq vars (cons (cons key value) vars))))
      vars)))


(defun grpclient--find-flags (bound)
  "Return list of flags defined in a file in BOUND."
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


(defun grpclient--define-hook (cmax)
  "Return elisp hook in current query entity until CMAX point."
  (save-excursion
    (when (search-forward-regexp grpclient-response-hook-regexp cmax t)
      (match-string-no-properties 2))))


(defun grpclient--build-command ()
  "Build and command string by current query entity."
  (save-excursion
    (goto-char (grpclient--current-min))
    (let* ((url-proto-method (cdr (string-split (grpclient--current-line) " ")))
           (url (cl-first url-proto-method))
           (vars (grpclient--replace-vars-with-override (grpclient--collect-vars-before)))
           (method (cl-second url-proto-method))
           (proto (cl-third url-proto-method))
           (cmax (grpclient--current-max))
           (flags (grpclient--find-flags (grpclient--current-min)))
           (body (progn
                   (forward-char)
                   (when (looking-at grpclient-response-hook-regexp)
                     (next-line))
                   (string-trim (buffer-substring-no-properties (min (point) cmax) cmax))))
           (cmd-builder (list "grpcurl"
                              (when body (concat "-d '" (encode-coding-string (grpclient--replace-all vars body) 'utf-8) "'"))
                              (string-join grpclient-default-flags " ")
                              (when flags (grpclient--replace-all vars flags))
                              (when proto (concat "-proto " (grpclient--replace-all vars proto)))
                              (grpclient--replace-all vars url)
                              (if method (grpclient--replace-all vars method) ""))))
      (string-join (grpclient--non-nil cmd-builder) " "))))


;;;###autoload
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


;;;###autoload
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


;;;###autoload
(defun grpclient-toggle-pretty-body ()
  "Pretty print body if it minimalized or conversely."
  (interactive)
  (or (grpclient-pretty-current)
      (grpclient-collaps-current)))


;;;###autoload
(defun grpclient-copy-grpcurl-to-clipboard ()
  "Build command and copy them into clipboard."
  (interactive)
  (let ((cmd (grpclient--build-command)))
    (kill-new cmd)
    (message cmd)))

;;;###autoload
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
  (let ((cmd (grpclient--build-command))
        (hook (grpclient--define-hook (grpclient--current-max)))
        (buf (get-buffer-create "*GRPC Response*"))
        (err (get-buffer-create "*GRPC Error*")))
    (with-current-buffer buf
      (if (fboundp 'json-mode) (json-mode) (js-mode))
      (erase-buffer))
    (with-current-buffer err (erase-buffer))
    (display-buffer buf)
    (set-process-sentinel
     (make-process :name "grpcurl" :buffer buf :stderr err
                   :command (list shell-file-name shell-command-switch cmd))
     (lambda (process _)
       (when (and (memq (process-status process) '(exit signal))
                  (buffer-live-p (process-buffer process)))
         (when (> (process-exit-status process) 0)
           (display-buffer err))
         (with-current-buffer (process-buffer process)
           (goto-char (point-min))
           (when hook
             (save-excursion
               (when (search-forward-regexp "^\{$" nil t)
                 (beginning-of-line)
                 (let ((json-body (buffer-substring-no-properties (point) (progn (forward-sexp) (point)))))
                   (with-temp-buffer
                     (insert json-body)
                     (goto-char (point-min))
                     (eval-expression (read hook)))))))
           (when-let ((win (get-buffer-window (current-buffer))))
             (set-window-point win (point-min)))))))))

(defvar grpclient--last-url nil)


;;;###autoload
(defun grpclient-describe ()
  "Describe things."
  (interactive)
  (let* ((url (setq grpclient--last-url (read-string "Enter url: " grpclient--last-url)))
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


(defvar grpclient-mode-hook nil)

(defvar grpclient-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-v") #'grpclient-send-current)
    (define-key map (kbd "C-c C-u") #'grpclient-copy-grpcurl-to-clipboard)
    (define-key map (kbd "C-c C-l") #'grpclient-describe)
    (define-key map (kbd "C-c C-c") #'grpclient-completion-complete)
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


(defun grpclient-completion--read (prompt collection &optional predicate require-match
                                            initial-input hist def inherit-input-method)
  "Read a choice from COLLECTION using `grpclient-completion-system'.

PROMPT and remaining arguments match `completing-read'."
  (let ((system (if (eq grpclient-completion-system 'auto)
                    (cond ((bound-and-true-p helm-mode) 'helm)
                          ((bound-and-true-p ivy-mode)  'ivy)
                          ((bound-and-true-p ido-mode)  'ido)
                          (t 'default))
                  grpclient-completion-system)))
    (pcase system
      ('default
       (completing-read prompt collection predicate require-match
                        initial-input hist def inherit-input-method))
      ('ido
       (ido-completing-read prompt collection predicate require-match
                            initial-input hist def inherit-input-method))
      ('helm
       (if (require 'helm nil 'noerror)
           (helm-comp-read prompt collection
                           :must-match require-match
                           :initial-input initial-input)
         (completing-read prompt collection predicate require-match
                          initial-input hist def inherit-input-method)))
      ('ivy
       (if (require 'ivy nil 'noerror)
           (ivy-completing-read prompt collection predicate require-match
                                initial-input hist def inherit-input-method)
         (completing-read prompt collection predicate require-match
                          initial-input hist def inherit-input-method)))
      ((pred functionp)
       (funcall system prompt collection predicate require-match
                initial-input hist def inherit-input-method))
      (_
       (completing-read prompt collection predicate require-match
                        initial-input hist def inherit-input-method)))))

;; --- Disk cache I/O --------------------------------------------------

(defun grpclient-completion--cache-file-path (server)
  "Return absolute cache file path for SERVER."
  (let ((safe (replace-regexp-in-string "[^a-zA-Z0-9._:-]" "_" server)))
    (expand-file-name (concat safe ".cache") grpclient-completion-cache-dir)))


(defun grpclient-completion--read-disk-cache (server)
  "Read cached reflection data for SERVER from disk.

Return nil if file is missing, stale, or corrupted."
  (let ((file (grpclient-completion--cache-file-path server)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (condition-case err
            (let* ((data (read (buffer-string)))
                   (fetched (alist-get "fetched-at" data nil nil #'equal)))
              (when (and fetched
                         (string= (alist-get "server" data "" nil #'equal) server)
                         (< (float-time
                             (time-subtract (current-time)
                                            (date-to-time fetched)))
                            grpclient-completion-cache-ttl))
                data))
          (error
           (message "Error loading cache file '%s': %s"
                    server
                    (error-message-string err))
           nil))))))


(defun grpclient-completion--write-disk-cache (server data)
  "Write reflection DATA for SERVER to disk.

If there is not method data function does nothing."
  (let ((file (grpclient-completion--cache-file-path server))
        (methods (alist-get "methods" data nil nil #'equal)))
    (when (and methods (append methods nil))
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert (prin1-to-string data))))))


(defun grpclient-completion--flags ()
  "Return combined flags for grpcurl commands (default + per-file)."
  (save-excursion
    (let* ((default (string-join grpclient-default-flags " "))
           (per-file (grpclient--find-flags (point-max))))
      (string-join (grpclient--non-nil (list default per-file)) " "))))


(defun grpclient-completion--run (fmt &rest args)
  "Run grpcurl with formatted, using FMT, ARGS, return non-empty output lines."
  (let* ((flags (grpclient-completion--flags))
         (cmd (format "grpcurl %s %s" flags (apply #'format fmt args))))
    (with-temp-buffer
      (let ((exit (call-process shell-file-name nil t nil
                                shell-command-switch cmd)))
        (unless (zerop exit)
          (error "Grpcurl failed (exit %d): %s" exit cmd))
        (split-string (buffer-string) "\n" t)))))


(defun grpclient-completion--fetch-services (server)
  "Fetch list of fully-qualified service names from SERVER."
  (grpclient-completion--run "%s list" server))


(defun grpclient-completion--proto-to-json (proto-name)
  "Convert protobuf snake_case field as PROTO-NAME to JSON camelCase.
\"legal_type\" → \"legalType\", \"selection_start\" → \"selectionStart\"."
  (let ((parts (split-string proto-name "_" t)))
    (concat (car parts)
            (mapconcat #'capitalize (cdr parts) ""))))


(defun grpclient-completion--fetch-all (server)
  "Fetch all rpc methods, request types, and message templates from SERVER.

Returns alist:
  (\"server\" . SERVER)
  (\"fetched-at\" . TIMESTAMP)
  (\"methods\" . [(\"Svc/Method\" REQUEST-TYPE TEMPLATE TYPES) ...])

TEMPLATE is an alist of (FIELD . DEFAULT) from -msg-template output.
TYPES is an alist of (JSON-FIELD . PROTO-TYPE-STRING) when available."
  (message "Fetching reflection data from %s..." server)
  (let* ((services (grpclient-completion--fetch-services server))
         (rpc-infos nil)         ; list of (method-key . request-type)
         (request-types nil)     ; list of unique request-type strings
         (methods nil))

    ;; Phase 1: describe each service and extract rpc method + request type
    (dolist (svc services)
      (let* ((lines (grpclient-completion--run "%s describe %s" server svc))
             (text (and lines (string-join lines "\n"))))
        (when text
          (let ((pos 0))
            ;; Match "rpc MethodName ( [stream] .RequestType )" ignoring whitespace variations
            (while (string-match "rpc \\([^ \t\n]+\\)\\s-*(\\s-*\\(?:stream \\)?\\.\\([^ )]+\\)\\s-*)" text pos)
              (let* ((method (match-string-no-properties 1 text))
                     (req-type (match-string-no-properties 2 text))
                     (method-key (concat svc "/" method)))
                (push (cons method-key req-type) rpc-infos)
                (cl-pushnew req-type request-types :test #'string=))
              (setq pos (match-end 0)))))))

    ;; Phase 2: fetch msg-template for each unique request type
    (let ((templates (make-hash-table :test 'equal))
          (types-map (make-hash-table :test 'equal)))
      (dolist (req-type request-types)
        (let* ((lines (grpclient-completion--run "-msg-template %s describe %s"
                                                     server req-type))
               (text (and lines (string-join lines "\n")))
               (json-start (when text
                             (string-match "Message template:\n" text)))
               (template (when (and json-start text)
                           (let ((json-key-type 'string))
                             (json-read-from-string
                              (substring text (match-end 0))))))
               (def-start (when text
                            (string-match "message \\(\\w+\\) {\n" text)))
               (types (when def-start
                        (let ((body-start (match-end 0))
                              (body-end (or json-start (length text)))
                              (types nil))
                          (dolist (line (split-string
                                         (substring text body-start body-end)
                                         "\n" t))
                            (when (string-match
                                    "^\\(?:\\(repeated\\|optional\\|required\\) \\)?\\([a-zA-Z][a-zA-Z0-9_.<>]*\\) +\\([a-zA-Z_][a-zA-Z0-9_]*\\) *="
                                   line)
                              (let* ((repeated (match-string 1 line))
                                     (ptype (match-string 2 line))
                                     (pname (match-string 3 line))
                                     (jname (grpclient-completion--proto-to-json pname))
                                     (type-str (if repeated
                                                   (concat "repeated " ptype)
                                                 ptype)))
                                (push (cons jname type-str) types))))
                          (nreverse types)))))
          (puthash req-type (when (consp template) template) templates)
          (puthash req-type types types-map)))

      ;; Build final methods vector
      (dolist (rpc (nreverse rpc-infos))
          (let* ((method-key (car rpc))
                 (req-type (cdr rpc))
                 (template (gethash req-type templates))
                 (types (gethash req-type types-map)))
            (push (vector method-key req-type template types) methods)))

    (message "Fetching reflection data from %s... done" server)
    `(("server" . ,server)
      ("fetched-at" . ,(format-time-string "%Y-%m-%dT%TZ" nil t))
      ("methods" . ,(vconcat (nreverse methods)))))))


(defun grpclient-completion--get-data (server)
  "Return reflection data for SERVER from disk or network."
  (or (grpclient-completion--read-disk-cache server)
      (let ((fresh (grpclient-completion--fetch-all server)))
        (grpclient-completion--write-disk-cache server fresh)
        fresh)))


(defun grpclient-completion--format-value (val)
  "Format template value VAL as a JSON literal for body insertion."
  (cond ((stringp val) (format "\"%s\"" val))
        ((numberp val) (number-to-string val))
        ((null val) "null")
        ((eq val :json-false) "false")
        ((eq val t) "true")
        ((vectorp val) (format "[%s]"
                               (string-join (mapcar #'grpclient-completion--format-value val) ",")))
        ((listp val)
         (let ((parts (mapcar (lambda (p)
                                (format "\"%s\":%s" (car p)
                                        (grpclient-completion--format-value (cdr p))))
                              val)))
           (format "{%s}" (string-join parts ","))))
        (t (progn
             (message "Unexpected literal %s" (prin1-to-string val))
             (format "%s" (prin1-to-string val))))))


(defun grpclient-completion--insert-complete (server method-key template)
  "After completing METHOD-KEY, insert body template.
SERVER is used for variable resolution; TEMPLATE is an alist."
  (let* ((short-name (and (string-match "/\\([^/]+\\)$" method-key)
                          (match-string 1 method-key)))
         (pairs (and template
                     (mapcar (lambda (p)
                               (let* ((key (car p))
                                      (val (cdr p))
                                      (base (format "\"%s\":%s" key
                                                    (grpclient-completion--format-value val))))
                                 base))
                             template)))
         (body (if pairs
                   (concat "{" (string-join pairs ",") "}")
                 "{}")))
    (insert (format "\n%s\n\n" body))))


;;;###autoload
(defun grpclient-completion-complete (&optional server insert-all)
  "Insert a complete gRPC request at point.

Prompts for a Service/Method using `grpclient-completion--read'
\(respects `grpclient-completion-system': auto-detects helm, ivy,
ido, or falls back to plain `completing-read').

INSERT-ALL boolean is used to force insertion of all available
methods.

Inserts:
  # Call <Method>
  GRPC <SERVER> <Service>/<Method>
  {<message template>}\n\n"
  (interactive)
  (save-excursion
    (let* ((server (or server (read-string "gRPC server address: ")))
           (data (grpclient-completion--get-data server))
           (methods (alist-get "methods" data nil nil #'equal))
           (method-names (mapcar (lambda (e) (aref e 0)) methods))
           (keys (if insert-all
                     (append method-names nil)
                   (list (grpclient-completion--read "Method: " method-names nil t)))))
      (dolist (method-key keys)
        (let ((entry (cl-find method-key methods
                              :key (lambda (e) (aref e 0))
                              :test #'string=)))
          (when entry
            (let* ((template (aref entry 2))
                   (short-name (and (string-match "/\\([^/]+\\)$" method-key)
                                    (match-string 1 method-key))))
              (insert (format "# Call %s\n" short-name))
              (insert (format "GRPC %s %s" server method-key))
              (grpclient-completion--insert-complete server method-key template))))))))


;;;###autoload
(defun grpclient-completion-refresh-cache (&optional server)
  "Force-refetch reflection data for SERVER.
Interactively, use the server from the current buffer header."
  (interactive)
  (unless server
    (setq server (read-string "gRPC server address: ")))
  (let ((file (grpclient-completion--cache-file-path server)))
    (when (file-exists-p file)
      (delete-file file)))
  (grpclient-completion--get-data server)
  (message "Reflection cache refreshed for %s" server))


(provide 'grpclient)

;;; grpclient.el ends here
