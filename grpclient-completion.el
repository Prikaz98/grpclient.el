;;; grpclient-completion.el --- Completion for grpclient-mode using gRPC reflection  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Miloš Tepić

;; Author: Miloš Tepić <tepcmils@gmail.com>
;; Version: 0.1
;; Keywords: grpc tools

;; This program is free software; you can redistribute it and/or modify
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

;; Provides ~grpclient-complete~ for ~grpclient-mode~: an interactive
;; command that prompts for a gRPC method (with completion via
;; `completing-read') and inserts a fully-formed request with JSON
;; body template and end-comment marker.
;;
;; Data flow:
;;   1. `grpcurl list <server>` → all service FQNs
;;   2. `grpcurl describe <server> <service>` → extract rpc methods + request types
;;   3. `grpcurl -msg-template <server> describe <request_type>` → extract JSON template
;;
;; All data is cached to disk (~/.emacs.d/.cache/grpcurl-autocomplete/).
;;
;; Usage:
;;   C-c C-c  or  M-x grpclient-complete
;;
;; Requires an :address variable at the top of the .grpc file:
;;   :address=grpcb.in:9000

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'grpclient)

;; --- Customization ---------------------------------------------------

(defcustom grpclient-completion-server-var ":address"
  "Buffer variable name that holds the gRPC server address."
  :type 'string
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

(defun grpclient--completing-read (prompt collection &optional predicate require-match
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

;; --- In-memory cache -------------------------------------------------

(defvar grpclient--completion-cache (make-hash-table :test 'equal)
  "In-memory cache: SERVER -> reflection data alist.")

;; --- Disk cache I/O --------------------------------------------------

(defun grpclient--completion-cache-file (server)
  "Return absolute cache file path for SERVER."
  (let ((safe (replace-regexp-in-string "[^a-zA-Z0-9._:-]" "_" server)))
    (expand-file-name (concat safe ".json") grpclient-completion-cache-dir)))

(defun grpclient--completion-read-disk-cache (server)
  "Read cached reflection data for SERVER from disk.
Return nil if file is missing, stale, or corrupted."
  (let ((file (grpclient--completion-cache-file server)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (condition-case nil
            (let* ((json-key-type 'string)
                   (data (json-read-from-string (buffer-string)))
                   (fetched (alist-get "fetched-at" data nil nil #'equal)))
              (when (and fetched
                         (string= (alist-get "server" data "" nil #'equal) server)
                         (< (float-time
                             (time-subtract (current-time)
                                            (date-to-time fetched)))
                            grpclient-completion-cache-ttl))
                data))
          (error nil))))))

(defun grpclient--completion-write-disk-cache (server data)
  "Write reflection DATA for SERVER to disk."
  (let ((file (grpclient--completion-cache-file server)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (json-encode data)))))

;; --- grpcurl interaction ---------------------------------------------

(defun grpclient--completion-flags ()
  "Return combined flags for grpcurl commands (default + per-file)."
  (save-excursion
    (let* ((default (string-join grpclient-default-flags " "))
           (per-file (grpclient--find-flags (point-max))))
      (string-join (grpclient--non-nil (list default per-file)) " "))))

(defun grpclient--completion-run (fmt &rest args)
  "Run grpcurl with formatted ARGS, return non-empty output lines."
  (let* ((flags (grpclient--completion-flags))
         (cmd (format "grpcurl %s %s" flags (apply #'format fmt args))))
    (with-temp-buffer
      (let ((exit (call-process shell-file-name nil t nil
                                shell-command-switch cmd)))
        (unless (zerop exit)
          (error "grpcurl failed (exit %d): %s" exit cmd))
        (split-string (buffer-string) "\n" t)))))

(defun grpclient--completion-fetch-services (server)
  "Fetch list of fully-qualified service names from SERVER."
  (condition-case nil
      (grpclient--completion-run "%s list" server)
    (error nil)))

(defun grpclient--completion-proto-to-json (proto-name)
  "Convert protobuf snake_case field name to JSON camelCase.
\"legal_type\" → \"legalType\", \"selection_start\" → \"selectionStart\"."
  (let ((parts (split-string proto-name "_" t)))
    (concat (car parts)
            (mapconcat #'capitalize (cdr parts) ""))))

;; --- Data retrieval with caching -------------------------------------

(defun grpclient--completion-fetch-all (server)
  "Fetch all rpc methods, request types, and message templates from SERVER.

Returns alist:
  (\"server\" . SERVER)
  (\"fetched-at\" . TIMESTAMP)
  (\"methods\" . [(\"Svc/Method\" REQUEST-TYPE TEMPLATE TYPES) ...])

TEMPLATE is an alist of (FIELD . DEFAULT) from -msg-template output.
TYPES is an alist of (JSON-FIELD . PROTO-TYPE-STRING) when available."
  (message "Fetching reflection data from %s..." server)
  (let* ((services (or (grpclient--completion-fetch-services server) nil))
         (rpc-infos nil)         ; list of (method-key . request-type)
         (request-types nil)     ; list of unique request-type strings
         (methods nil))

    ;; Phase 1: describe each service and extract rpc method + request type
    (dolist (svc services)
      (let* ((lines (condition-case nil
                        (grpclient--completion-run "%s describe %s" server svc)
                      (error nil)))
             (text (and lines (string-join lines "\n"))))
        (when text
          (let ((pos 0))
            (while (string-match "rpc \\([^ \t\n]+\\) ( \\.\\([^ )]+\\) )" text pos)
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
        (let* ((lines (condition-case nil
                          (grpclient--completion-run "-msg-template %s describe %s"
                                                     server req-type)
                        (error nil)))
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
                                    "^\\(?:\\(repeated\\) \\)?\\([a-zA-Z][a-zA-Z0-9_.]*\\) +\\([a-z_][a-zA-Z0-9_]*\\) *="
                                   line)
                              (let* ((repeated (match-string 1 line))
                                     (ptype (match-string 2 line))
                                     (pname (match-string 3 line))
                                     (jname (grpclient--completion-proto-to-json pname))
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

(defun grpclient--completion-get-data (server)
  "Return reflection data for SERVER from memory, disk, or network."
  (or (gethash server grpclient--completion-cache)
      (let ((disk (grpclient--completion-read-disk-cache server)))
        (when disk
          (puthash server disk grpclient--completion-cache)
          disk))
      (let ((fresh (grpclient--completion-fetch-all server)))
        (puthash server fresh grpclient--completion-cache)
        (grpclient--completion-write-disk-cache server fresh)
        fresh)))

;; --- Buffer helpers --------------------------------------------------

(defun grpclient--completion-server-from-buffer ()
  "Get server address from buffer-header variable."
  (save-excursion
    (goto-char (point-min))
    (let ((re (concat "^" (regexp-quote grpclient-completion-server-var) "=\\(.+\\)$")))
      (when (re-search-forward re nil t)
        (match-string-no-properties 1)))))

(defun grpclient--completion-resolve (str)
  "Resolve variable references in STR using buffer header vars."
  (let ((vars (grpclient--replace-vars-with-override
               (grpclient--collect-vars-before))))
    (if (stringp str)
        (grpclient--replace-all vars str)
      str)))

;; --- Body and end-comment insertion ----------------------------------

(defun grpclient--completion-format-value (val)
  "Format template value VAL as a JSON literal for body insertion."
  (cond ((stringp val) (format "\"%s\"" val))
        ((numberp val) (number-to-string val))
        ((null val) "null")
        ((eq val :json-false) "false")
        ((eq val t) "true")
        ((listp val)
         (let ((parts (mapcar (lambda (p)
                                (format "\"%s\": %s" (car p)
                                        (grpclient--completion-format-value (cdr p))))
                              val)))
           (format "{ %s }" (string-join parts ", "))))
        (t (format "\"%s\"" (prin1-to-string val)))))

(defun grpclient--completion-insert-complete (server method-key template)
  "After completing METHOD-KEY, insert body template and # end.
SERVER is used for variable resolution; TEMPLATE is an alist."
  (let* ((short-name (and (string-match "/\\([^/]+\\)$" method-key)
                          (match-string 1 method-key)))
         (pairs (and template
                     (mapcar (lambda (p)
                               (let* ((key (car p))
                                      (val (cdr p))
                                      (base (format "    \"%s\": %s" key
                                                    (grpclient--completion-format-value val))))
                                 base))
                             template)))
         (body (if pairs
                   (concat "{\n" (string-join pairs ",\n") "\n}")
                 "{}")))
    (insert (concat "\n" body "\n\n# End " short-name "\n"))))

;; --- Interactive commands --------------------------------------------

;;;###autoload
(defun grpclient-complete ()
  "Insert a complete gRPC request at point.

Prompts for a Service/Method using `grpclient--completing-read'
(respects `grpclient-completion-system': auto-detects helm, ivy,
ido, or falls back to plain `completing-read').

Inserts:
  # Call <Method>
  GRPC :address <Service>/<Method>
  {<message template>}

  # end <Method>"
  (interactive)
  (let* ((server (grpclient--completion-server-from-buffer))
         (data (and server
                    (condition-case nil
                        (grpclient--completion-get-data server)
                      (error nil))))
         (methods (alist-get "methods" data nil nil #'equal))
         (all (and methods (append methods nil))))
    (unless all
      (user-error "No reflection data; set %s in the buffer or run grpclient-refresh-cache"
                  grpclient-completion-server-var))
    (let* ((method-key (grpclient--completing-read "Method: "
                                                    (mapcar (lambda (e) (aref e 0)) all)
                                                    nil t nil nil))
           (entry (cl-find method-key all
                           :key (lambda (e) (aref e 0))
                           :test #'string=)))
      (when entry
        (let* ((template (aref entry 2))
               (short-name (and (string-match "/\\([^/]+\\)$" method-key)
                                (match-string 1 method-key))))
          (insert (format "# Call %s\n" short-name))
          (insert (format "GRPC :address %s" method-key))
          (let ((grpc-end (point)))
            (grpclient--completion-insert-complete
             server method-key template)
            (goto-char grpc-end)))))))

;;;###autoload
(defun grpclient-refresh-cache (&optional server)
  "Force-refetch reflection data for SERVER.
Interactively, use the server from the current buffer header."
  (interactive)
  (unless server
    (setq server (grpclient--completion-server-from-buffer)))
  (unless server
    (user-error "No server found; set %s in the buffer header"
                grpclient-completion-server-var))
  (remhash server grpclient--completion-cache)
  (let ((file (grpclient--completion-cache-file server)))
    (when (file-exists-p file)
      (delete-file file)))
  (grpclient--completion-get-data server)
  (message "Reflection cache refreshed for %s" server))

(provide 'grpclient-completion)

;; Compatibility stub for users migrating from grpclient-capf-mode.
;;;###autoload
(define-minor-mode grpclient-capf-mode
  "Obsolete — use `grpclient-complete' instead (\\[grpclient-complete])."
  :lighter ""
  (if grpclient-capf-mode
      (message "grpclient-capf-mode is removed. Use `grpclient-complete' (C-c C-c) instead.")
    (message "grpclient-capf-mode is removed. Use `grpclient-complete' (C-c C-c) instead.")))

;;; grpclient-completion.el ends here
