;;; grpclient-completion-integration-test.el --- Integration tests with real gRPC server  -*- lexical-binding: t; -*-

;; Tests start the example gRPC server and run grpcurl against it.
;; Skipped automatically when grpcurl or Python/grpcio are missing.

(require 'ert)
(require 'grpclient-completion)

;; ---------------------------------------------------------------------------
;; Server fixture
;; ---------------------------------------------------------------------------

(defvar grpclient-test-server-process nil
  "The Python gRPC test server subprocess.")

(defvar grpclient-test-server-address nil
  "Bound address of the test server (e.g. \"127.0.0.1:45231\").")

(defun grpclient-test-server-project-root ()
  "Return the project root directory."
  (if load-file-name
      (file-name-directory (directory-file-name (file-name-directory load-file-name)))
    default-directory))

(defun grpclient-test-server-python ()
  "Return path to a python3 binary that has grpc+reflection, or nil."
  (let ((candidates (list "python3"
                          (expand-file-name "examples/.venv/bin/python3"
                                            (grpclient-test-server-project-root)))))
    (cl-find-if
     (lambda (py)
       (and (executable-find py)
            (with-temp-buffer
              (zerop (call-process py nil t nil "-c"
                                   "import grpc; from grpc_reflection.v1alpha import reflection")))))
     candidates)))

(defun grpclient-test-server-check-prereqs ()
  "Return non-nil when grpcurl and Python gRPC server deps are available."
  (and (executable-find "grpcurl")
       (not (null (grpclient-test-server-python)))))

(defun grpclient-test-server-setup ()
  "Ensure the example server venv and generated stubs exist."
  (let ((default-directory (grpclient-test-server-project-root)))
    (unless (and (file-exists-p "examples/.venv/bin/python3")
                 (file-exists-p "examples/server/hello_pb2_grpc.py"))
      (message "Setting up example server venv (one-time)...")
      (call-process "python3" nil nil nil "-m" "venv" "examples/.venv")
      (call-process "examples/.venv/bin/pip" nil nil nil
                    "install" "-q" "-r" "examples/server/requirements.txt")
      (call-process "examples/.venv/bin/python" nil nil nil
                    "-m" "grpc_tools.protoc"
                    "-Iexamples"
                    "--python_out=examples/server"
                    "--grpc_python_out=examples/server"
                    "examples/hello.proto"
                    "examples/hello_v3.proto"))))

(defun grpclient-test-server-start ()
  "Start the example gRPC server and capture its address.
Signal an error if the server cannot be started."
  (grpclient-test-server-setup)
  (let* ((python (grpclient-test-server-python))
         (server-script (expand-file-name "examples/server/server.py"
                                          (grpclient-test-server-project-root)))
         (ready nil)
         (output nil))
    (setq grpclient-test-server-process
          (make-process :name "grpclient-test-server"
                        :buffer (generate-new-buffer " *grpclient-test-server*")
                        :command (list python server-script)
                        :noquery t
                        :filter (lambda (_proc string)
                                  (push string output)
                                  (when (and (not ready)
                                             (string-match "running on port" string))
                                    (setq ready t)
                                    (setq grpclient-test-server-address "127.0.0.1:9000")))))
    (let ((tries 0))
      (while (and (not ready)
                  (eq (process-status grpclient-test-server-process) 'run)
                  (< tries 100))
        (sleep-for 0.1)
        (accept-process-output grpclient-test-server-process 0.1 nil t)
        (cl-incf tries)))
    (unless ready
      (grpclient-test-server-stop)
      (error "Test gRPC server did not start in time.  Output: %s"
             (apply #'concat (nreverse output))))))

(defun grpclient-test-server-stop ()
  "Stop the Python gRPC test server."
  (when (and grpclient-test-server-process
             (eq (process-status grpclient-test-server-process) 'run))
    (signal-process grpclient-test-server-process 'TERM)
    (let ((tries 0))
      (while (and (eq (process-status grpclient-test-server-process) 'run)
                  (< tries 50))
        (sleep-for 0.1)
        (cl-incf tries))))
  (when (process-live-p grpclient-test-server-process)
    (kill-process grpclient-test-server-process))
  (setq grpclient-test-server-process nil
        grpclient-test-server-address nil))

(defmacro with-grpc-test-server (&rest body)
  "Run BODY with the example gRPC test server, tearing it down afterwards.
Skips with :skipped result when prerequisites are missing."
  (declare (indent 0))
  `(if (not (grpclient-test-server-check-prereqs))
       (ert-skip "grpcurl or Python gRPC deps not available")
     (unwind-protect
         (progn
           (grpclient-test-server-start)
           ,@body)
       (grpclient-test-server-stop))))

;; ---------------------------------------------------------------------------
;; Tests
;; ---------------------------------------------------------------------------

(ert-deftest server-list-services ()
  (with-grpc-test-server
    (let ((services (grpclient--completion-fetch-services grpclient-test-server-address)))
      (should (member "hello.HelloService" services))
      (should (member "hello_v3.HelloServiceV3" services))
      (should (>= (length services) 2)))))

(ert-deftest server-fetch-all-structure ()
  (with-grpc-test-server
    (let* ((data (grpclient--completion-fetch-all grpclient-test-server-address))
           (methods (alist-get "methods" data nil nil #'equal)))
      (should data)
      (should (>= (length methods) 4))

      ;; hello.HelloService/SayHello — multi-field template
      (let* ((entry (cl-find "hello.HelloService/SayHello" methods
                             :key (lambda (e) (aref e 0)) :test #'string=))
             (req-type (aref entry 1))
             (template (aref entry 2)))
        (should entry)
        (should (string= req-type "hello.HelloRequest"))
        (should (consp template))
        (should (assoc "greeting" template))
        (should (assoc "name" template)))

      ;; hello.HelloService/SayHelloStream — has stream keyword
      (let ((entry (cl-find "hello.HelloService/SayHelloStream" methods
                            :key (lambda (e) (aref e 0)) :test #'string=)))
        (should entry)
        (should (string= (aref entry 1) "hello.HelloRequest")))

      ;; hello_v3.HelloServiceV3/SayHello — single-field template
      (let* ((entry (cl-find "hello_v3.HelloServiceV3/SayHello" methods
                             :key (lambda (e) (aref e 0)) :test #'string=))
             (template (aref entry 2)))
        (should entry)
        (should (consp template))
        (should (assoc "greeting" template)))

      ;; hello_v3.HelloServiceV3/SayMultiType — multi-type template
      (let* ((entry (cl-find "hello_v3.HelloServiceV3/SayMultiType" methods
                             :key (lambda (e) (aref e 0)) :test #'string=))
             (template (aref entry 2)))
        (should entry)
        (should (consp template))
        (should (assoc "fString" template))
        (should (assoc "fInt32" template))
        (should (assoc "fBool" template))))))

(ert-deftest server-unknown-server ()
  (with-grpc-test-server
    (let ((data (grpclient--completion-fetch-all "127.0.0.1:1")))
      (should data)
      (should (zerop (length (alist-get "methods" data nil nil #'equal)))))))

(ert-deftest server-cache-roundtrip ()
  (with-grpc-test-server
    (let ((data (grpclient--completion-get-data grpclient-test-server-address)))
      (should data)
      (should (>= (length (alist-get "methods" data nil nil #'equal)) 2))
      (let ((cached (grpclient--completion-read-disk-cache grpclient-test-server-address)))
        (should cached)
        (should (equal (alist-get "server" cached nil nil #'equal)
                       grpclient-test-server-address))))))

(provide 'grpclient-completion-integration-test)
;;; grpclient-completion-integration-test.el ends here
