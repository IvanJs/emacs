;;; server.el --- Lisp code for GNU Emacs running as server process

;; Copyright (C) 1986, 1987, 1992, 1994, 1995, 1996, 1997, 1998, 1999, 2000,
;;   2001, 2002, 2003, 2004, 2005, 2006, 2007 Free Software Foundation, Inc.

;; Author: William Sommerfeld <wesommer@athena.mit.edu>
;; Maintainer: FSF
;; Keywords: processes

;; Changes by peck@sun.com and by rms.
;; Overhaul by Karoly Lorentey <lorentey@elte.hu> for multi-tty support.

;; This file is part of GNU Emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; This Lisp code is run in Emacs when it is to operate as
;; a server for other processes.

;; Load this library and do M-x server-edit to enable Emacs as a server.
;; Emacs opens up a socket for communication with clients.  If there are no
;; client buffers to edit, server-edit acts like (switch-to-buffer
;; (other-buffer))

;; When some other program runs "the editor" to edit a file,
;; "the editor" can be the Emacs client program ../lib-src/emacsclient.
;; This program transmits the file names to Emacs through
;; the server subprocess, and Emacs visits them and lets you edit them.

;; Note that any number of clients may dispatch files to Emacs to be edited.

;; When you finish editing a Server buffer, again call server-edit
;; to mark that buffer as done for the client and switch to the next
;; Server buffer.  When all the buffers for a client have been edited
;; and exited with server-edit, the client "editor" will return
;; to the program that invoked it.

;; Your editing commands and Emacs's display output go to and from
;; the terminal in the usual way.  Thus, server operation is possible
;; only when Emacs can talk to the terminal at the time you invoke
;; the client.  This is possible in four cases:

;; 1. On a window system, where Emacs runs in one window and the
;; program that wants to use "the editor" runs in another.

;; 2. On a multi-terminal system, where Emacs runs on one terminal and the
;; program that wants to use "the editor" runs on another.

;; 3. When the program that wants to use "the editor" is running
;; as a subprocess of Emacs.

;; 4. On a system with job control, when Emacs is suspended, the program
;; that wants to use "the editor" will stop and display
;; "Waiting for Emacs...".  It can then be suspended, and Emacs can be
;; brought into the foreground for editing.  When done editing, Emacs is
;; suspended again, and the client program is brought into the foreground.

;; The buffer local variable "server-buffer-clients" lists
;; the clients who are waiting for this buffer to be edited.
;; The global variable "server-clients" lists all the waiting clients,
;; and which files are yet to be edited for each.

;;; Code:

(eval-when-compile (require 'cl))

(defgroup server nil
  "Emacs running as a server process."
  :group 'external)

(defcustom server-use-tcp nil
  "If non-nil, use TCP sockets instead of local sockets."
  :set #'(lambda (sym val)
           (unless (featurep 'make-network-process '(:family local))
             (setq val t)
             (unless load-in-progress
               (message "Local sockets unsupported, using TCP sockets")))
           (when val (random t))
           (set-default sym val))
  :group 'server
  :type 'boolean
  :version "22.1")

(defcustom server-host nil
  "The name or IP address to use as host address of the server process.
If set, the server accepts remote connections; otherwise it is local."
  :group 'server
  :type '(choice
          (string :tag "Name or IP address")
          (const :tag "Local" nil))
  :version "22.1")
(put 'server-host 'risky-local-variable t)

(defcustom server-auth-dir "~/.emacs.d/server/"
  "Directory for server authentication files."
  :group 'server
  :type 'directory
  :version "22.1")
(put 'server-auth-dir 'risky-local-variable t)

(defcustom server-raise-frame t
  "If non-nil, raise frame when switching to a buffer."
  :group 'server
  :type 'boolean
  :version "22.1")

(defcustom server-visit-hook nil
  "Hook run when visiting a file for the Emacs server."
  :group 'server
  :type 'hook)

(defcustom server-switch-hook nil
  "Hook run when switching to a buffer for the Emacs server."
  :group 'server
  :type 'hook)

(defcustom server-done-hook nil
  "Hook run when done editing a buffer for the Emacs server."
  :group 'server
  :type 'hook)

(defvar server-process nil
  "The current server process.")

(defvar server-clients nil
  "List of current server clients.
Each element is (PROC PROPERTIES...) where PROC is a process object,
and PROPERTIES is an association list of client properties.")

(defvar server-buffer-clients nil
  "List of client processes requesting editing of current buffer.")
(make-variable-buffer-local 'server-buffer-clients)
;; Changing major modes should not erase this local.
(put 'server-buffer-clients 'permanent-local t)

(defcustom server-window nil
  "Specification of the window to use for selecting Emacs server buffers.
If nil, use the selected window.
If it is a function, it should take one argument (a buffer) and
display and select it.  A common value is `pop-to-buffer'.
If it is a window, use that.
If it is a frame, use the frame's selected window.

It is not meaningful to set this to a specific frame or window with Custom.
Only programs can do so."
  :group 'server
  :version "22.1"
  :type '(choice (const :tag "Use selected window"
			:match (lambda (widget value)
				 (not (functionp value)))
			nil)
		 (function-item :tag "Use pop-to-buffer" pop-to-buffer)
		 (function :tag "Other function")))

(defcustom server-temp-file-regexp "^/tmp/Re\\|/draft$"
  "Regexp matching names of temporary files.
These are deleted and reused after each edit by the programs that
invoke the Emacs server."
  :group 'server
  :type 'regexp)

(defcustom server-kill-new-buffers t
  "Whether to kill buffers when done with them.
If non-nil, kill a buffer unless it already existed before editing
it with Emacs server.  If nil, kill only buffers as specified by
`server-temp-file-regexp'.
Please note that only buffers are killed that still have a client,
i.e. buffers visited which \"emacsclient --no-wait\" are never killed in
this way."
  :group 'server
  :type 'boolean
  :version "21.1")

(or (assq 'server-buffer-clients minor-mode-alist)
    (push '(server-buffer-clients " Server") minor-mode-alist))

(defvar server-existing-buffer nil
  "Non-nil means the buffer existed before the server was asked to visit it.
This means that the server should not kill the buffer when you say you
are done with it in the server.")
(make-variable-buffer-local 'server-existing-buffer)

(defvar server-name "server")

(defvar server-socket-dir nil
  "The directory in which to place the server socket.
Initialized by `server-start'.")

(defun server-client (proc)
  "Return the Emacs client corresponding to PROC.
PROC must be a process object.
The car of the result is PROC; the cdr is an association list.
See `server-client-get' and `server-client-set'."
  (assq proc server-clients))

(defun server-client-get (client property)
  "Get the value of PROPERTY in CLIENT.
CLIENT may be a process object, or a client returned by `server-client'.
Return nil if CLIENT has no such property."
  (or (listp client) (setq client (server-client client)))
  (cdr (assq property (cdr client))))

(defun server-client-set (client property value)
  "Set the PROPERTY to VALUE in CLIENT, and return VALUE.
CLIENT may be a process object, or a client returned by `server-client'."
  (let (p proc)
    (if (listp client)
	(setq proc (car client))
      (setq proc client
	    client (server-client client)))
    (setq p (assq property client))
    (cond
     (p (setcdr p value))
     (client (setcdr client (cons (cons property value) (cdr client))))
     (t (setq server-clients
	      `((,proc (,property . ,value)) . ,server-clients))))
    value))

(defun server-clients-with (property value)
  "Return a list of clients with PROPERTY set to VALUE."
  (let (result)
    (dolist (client server-clients result)
      (when (equal value (server-client-get client property))
	(setq result (cons (car client) result))))))

(defun server-add-client (proc)
  "Create a client for process PROC, if it doesn't already have one.
New clients have no properties."
  (unless (server-client proc)
    (setq server-clients (cons (cons proc nil)
			       server-clients))))

(defun server-getenv-from (env variable)
  "Get the value of VARIABLE in ENV.
VARIABLE should be a string.  Value is nil if VARIABLE is
undefined in ENV.  Otherwise, value is a string.

ENV should be in the same format as `process-environment'."
  (let (entry result)
    (while (and env (null result))
      (setq entry (car env)
	    env (cdr env))
      (if (and (> (length entry) (length variable))
	       (eq ?= (aref entry (length variable)))
	       (equal variable (substring entry 0 (length variable))))
	  (setq result (substring entry (+ (length variable) 1)))))
    result))

(defmacro server-with-environment (env vars &rest body)
  "Evaluate BODY with environment variables VARS set to those in ENV.
The environment variables are then restored to their previous values.

VARS should be a list of strings.
ENV should be in the same format as `process-environment'."
  (declare (indent 2))
  (let ((oldvalues (make-symbol "oldvalues"))
	(var (make-symbol "var"))
	(value (make-symbol "value"))
	(pair (make-symbol "pair")))
    `(let (,oldvalues)
       (dolist (,var ,vars)
	 (let ((,value (server-getenv-from ,env ,var)))
	   (setq ,oldvalues (cons (cons ,var (getenv ,var)) ,oldvalues))
	   (setenv ,var ,value)))
       (unwind-protect
	   (progn ,@body)
	 (dolist (,pair ,oldvalues)
	   (setenv (car ,pair) (cdr ,pair)))))))

(defun server-delete-client (client &optional noframe)
  "Delete CLIENT, including its buffers, terminals and frames.
If NOFRAME is non-nil, let the frames live.  (To be used from
`delete-frame-functions'.)"
  (server-log (concat "server-delete-client" (if noframe " noframe"))
	      client)
  ;; Force a new lookup of client (prevents infinite recursion).
  (setq client (server-client
		(if (listp client) (car client) client)))
  (let ((proc (car client))
	(buffers (server-client-get client 'buffers)))
    (when client

      ;; Kill the client's buffers.
      (dolist (buf buffers)
	(when (buffer-live-p buf)
	  (with-current-buffer buf
	    ;; Kill the buffer if necessary.
	    (when (and (equal server-buffer-clients
			      (list proc))
		       (or (and server-kill-new-buffers
				(not server-existing-buffer))
			   (server-temp-file-p))
		       (not (buffer-modified-p)))
	      (let (flag)
		(unwind-protect
		    (progn (setq server-buffer-clients nil)
			   (kill-buffer (current-buffer))
			   (setq flag t))
		  (unless flag
		    ;; Restore clients if user pressed C-g in `kill-buffer'.
		    (setq server-buffer-clients (list proc)))))))))

      ;; Delete the client's frames.
      (unless noframe
	(dolist (frame (frame-list))
	  (when (and (frame-live-p frame)
		     (equal proc (frame-parameter frame 'client)))
	    ;; Prevent `server-handle-delete-frame' from calling us
	    ;; recursively.
	    (set-frame-parameter frame 'client nil)
	    (delete-frame frame))))

      (setq server-clients (delq client server-clients))

      ;; Delete the client's tty.
      (let ((terminal (server-client-get client 'terminal)))
	(when (eq (terminal-live-p terminal) t)
	  (delete-terminal terminal)))

      ;; Delete the client's process.
      (if (eq (process-status (car client)) 'open)
	  (delete-process (car client)))

      (server-log "Deleted" proc))))

(defun server-log (string &optional client)
  "If a *server* buffer exists, write STRING to it for logging purposes.
If CLIENT is non-nil, add a description of it to the logged
message."
  (when (get-buffer "*server*")
    (with-current-buffer "*server*"
      (goto-char (point-max))
      (insert (current-time-string)
	      (cond
	       ((null client) " ")
	       ((listp client) (format " %s: " (car client)))
	       (t (format " %s: " client)))
	      string)
      (or (bolp) (newline)))))

(defun server-sentinel (proc msg)
  "The process sentinel for Emacs server connections."
  ;; If this is a new client process, set the query-on-exit flag to nil
  ;; for this process (it isn't inherited from the server process).
  (when (and (eq (process-status proc) 'open)
	     (process-query-on-exit-flag proc))
    (set-process-query-on-exit-flag proc nil))
  ;; Delete the associated connection file, if applicable.
  ;; This is actually problematic: the file may have been overwritten by
  ;; another Emacs server in the mean time, so it's not ours any more.
  ;; (and (process-contact proc :server)
  ;;      (eq (process-status proc) 'closed)
  ;;      (ignore-errors (delete-file (process-get proc :server-file))))
  (server-log (format "Status changed to %s: %s" (process-status proc) msg) proc)
  (server-delete-client proc))

(defun server-handle-delete-frame (frame)
  "Delete the client connection when the emacsclient frame is deleted."
  (let ((proc (frame-parameter frame 'client)))
    (when (and (frame-live-p frame)
	       proc
	       ;; See if this is the last frame for this client.
	       (>= 1 (let ((frame-num 0))
		      (dolist (f (frame-list))
			(when (eq proc (frame-parameter f 'client))
			  (setq frame-num (1+ frame-num))))
		      frame-num)))
      (server-log (format "server-handle-delete-frame, frame %s" frame) proc)
      (server-delete-client proc 'noframe)))) ; Let delete-frame delete the frame later.

(defun server-handle-suspend-tty (terminal)
  "Notify the emacsclient process to suspend itself when its tty device is suspended."
  (dolist (proc (server-clients-with 'terminal terminal))
    (server-log (format "server-handle-suspend-tty, terminal %s" terminal) proc)
    (condition-case err
	(server-send-string proc "-suspend \n")
      (file-error (condition-case nil (server-delete-client proc) (error nil))))))

(defun server-unquote-arg (arg)
  "Remove &-quotation from ARG.
See `server-quote-arg' and `server-process-filter'."
  (replace-regexp-in-string
   "&." (lambda (s)
	  (case (aref s 1)
	    (?& "&")
	    (?- "-")
	    (?n "\n")
	    (t " ")))
   arg t t))

(defun server-quote-arg (arg)
  "In ARG, insert a & before each &, each space, each newline, and -.
Change spaces to underscores, too, so that the return value never
contains a space.

See `server-unquote-arg' and `server-process-filter'."
  (replace-regexp-in-string
   "[-&\n ]" (lambda (s)
	       (case (aref s 0)
		 (?& "&&")
		 (?- "&-")
		 (?\n "&n")
		 (?\s "&_")))
   arg t t))

(defun server-send-string (proc string)
  "A wrapper around `proc-send-string' for logging."
  (server-log (concat "Sent " string) proc)
  (process-send-string proc string))

(defun server-ensure-safe-dir (dir)
  "Make sure DIR is a directory with no race-condition issues.
Creates the directory if necessary and makes sure:
- there's no symlink involved
- it's owned by us
- it's not readable/writable by anybody else."
  (setq dir (directory-file-name dir))
  (let ((attrs (file-attributes dir)))
    (unless attrs
      (letf (((default-file-modes) ?\700)) (make-directory dir t))
      (setq attrs (file-attributes dir)))
    ;; Check that it's safe for use.
    (unless (and (eq t (car attrs)) (eql (nth 2 attrs) (user-uid))
                 (or (eq system-type 'windows-nt)
                     (zerop (logand ?\077 (file-modes dir)))))
      (error "The directory %s is unsafe" dir))))

;;;###autoload
(defun server-start (&optional leave-dead)
  "Allow this Emacs process to be a server for client processes.
This starts a server communications subprocess through which
client \"editors\" can send your editing commands to this Emacs
job.  To use the server, set up the program `emacsclient' in the
Emacs distribution as your standard \"editor\".

Optional argument LEAVE-DEAD (interactively, a prefix arg) means just
kill any existing server communications subprocess."
  (interactive "P")
  (when (or
	 (not server-clients)
	 (yes-or-no-p
	  "The current server still has clients; delete them? "))
    ;; It is safe to get the user id now.
    (setq server-socket-dir (or server-socket-dir
				(format "/tmp/emacs%d" (user-uid))))
    (when server-process
      ;; kill it dead!
      (ignore-errors (delete-process server-process)))
    ;; Delete the socket files made by previous server invocations.
    (condition-case ()
	(delete-file (expand-file-name server-name server-socket-dir))
      (error nil))
    ;; If this Emacs already had a server, clear out associated status.
    (while server-clients
      (server-delete-client (car server-clients)))
    ;; Now any previous server is properly stopped.
    (if leave-dead
	(progn
	  (server-log (message "Server stopped"))
	  (setq server-process nil))
      (let* ((server-dir (if server-use-tcp server-auth-dir server-socket-dir))
	     (server-file (expand-file-name server-name server-dir)))
	;; Make sure there is a safe directory in which to place the socket.
	(server-ensure-safe-dir server-dir)
	;; Remove any leftover socket or authentication file.
	(ignore-errors (delete-file server-file))
	(when server-process
	  (server-log (message "Restarting server")))
	(letf (((default-file-modes) ?\700))
	  (add-hook 'suspend-tty-functions 'server-handle-suspend-tty)
	  (add-hook 'delete-frame-functions 'server-handle-delete-frame)
	  (add-hook 'kill-buffer-query-functions 'server-kill-buffer-query-function)
	  (add-hook 'kill-emacs-query-functions 'server-kill-emacs-query-function)
	  (setq server-process
		(apply #'make-network-process
		       :name server-name
		       :server t
		       :noquery t
		       :sentinel 'server-sentinel
		       :filter 'server-process-filter
		       ;; We must receive file names without being decoded.
		       ;; Those are decoded by server-process-filter according
		       ;; to file-name-coding-system.
		       :coding 'raw-text
		       ;; The rest of the args depends on the kind of socket used.
		       (if server-use-tcp
			   (list :family nil
				 :service t
				 :host (or server-host 'local)
				 :plist '(:authenticated nil))
			 (list :family 'local
			       :service server-file
			       :plist '(:authenticated t)))))
	  (unless server-process (error "Could not start server process"))
	  (when server-use-tcp
	    (let ((auth-key
		   (loop
		    ;; The auth key is a 64-byte string of random chars in the
		    ;; range `!'..`~'.
		    for i below 64
		    collect (+ 33 (random 94)) into auth
		    finally return (concat auth))))
	      (process-put server-process :auth-key auth-key)
	      (with-temp-file server-file
		(set-buffer-multibyte nil)
		(setq buffer-file-coding-system 'no-conversion)
		(insert (format-network-address
			 (process-contact server-process :local))
			" " (int-to-string (emacs-pid))
			"\n" auth-key)))))))))

;;;###autoload
(define-minor-mode server-mode
  "Toggle Server mode.
With ARG, turn Server mode on if ARG is positive, off otherwise.
Server mode runs a process that accepts commands from the
`emacsclient' program.  See `server-start' and Info node `Emacs server'."
  :global t
  :group 'server
  :version "22.1"
  ;; Fixme: Should this check for an existing server socket and do
  ;; nothing if there is one (for multiple Emacs sessions)?
  (server-start (not server-mode)))

(defun* server-process-filter (proc string)
  "Process a request from the server to edit some files.
PROC is the server process.  STRING consists of a sequence of
commands prefixed by a dash.  Some commands have arguments; these
are &-quoted and need to be decoded by `server-unquote-arg'.  The
filter parses and executes these commands.

To illustrate the protocol, here is an example command that
emacsclient sends to create a new X frame (note that the whole
sequence is sent on a single line):

	-version 21.3.50 xterm
	-env HOME /home/lorentey
	-env DISPLAY :0.0
	... lots of other -env commands
	-display :0.0
	-window-system

The server normally sends back the single command `-good-version'
as a response.

The following commands are accepted by the server:

`-auth AUTH-STRING'
  Authenticate the client using the secret authentication string
  AUTH_STRING.

`-version CLIENT-VERSION'
  Check version numbers between server and client, and signal an
  error if there is a mismatch.  The server replies with
  `-good-version' to confirm the match.

`-env NAME=VALUE'
  An environment variable on the client side.

`-dir DIRNAME'
  The current working directory of the client process.

`-current-frame'
  Forbid the creation of new frames.

`-nowait'
  Request that the next frame created should not be
  associated with this client.

`-display DISPLAY'
  Set the display name to open X frames on.

`-position LINE[:COLUMN]'
  Go to the given line and column number
  in the next file opened.

`-file FILENAME'
  Load the given file in the current frame.

`-eval EXPR'
  Evaluate EXPR as a Lisp expression and return the
  result in -print commands.

`-window-system'
  Open a new X frame.

`-tty DEVICENAME TYPE'
  Open a new tty frame at the client.

`-suspend'
  Suspend this tty frame.  The client sends this string in
  response to SIGTSTP and SIGTTOU.  The server must cease all I/O
  on this tty until it gets a -resume command.

`-resume'
  Resume this tty frame. The client sends this string when it
  gets the SIGCONT signal and it is the foreground process on its
  controlling tty.

`-ignore COMMENT'
  Do nothing, but put the comment in the server
  log.  Useful for debugging.


The following commands are accepted by the client:

`-good-version'
  Signals a version match between the client and the server.

`-emacs-pid PID'
  Describes the process id of the Emacs process;
  used to forward window change signals to it.

`-window-system-unsupported'
  Signals that the server does not
  support creating X frames; the client must try again with a tty
  frame.

`-print STRING'
  Print STRING on stdout.  Used to send values
  returned by -eval.

`-error DESCRIPTION'
  Signal an error (but continue processing).

`-suspend'
  Suspend this terminal, i.e., stop the client process.  Sent
  when the user presses C-z."
  (server-log (concat "Received " string) proc)
  ;; First things first: let's check the authentication
  (unless (process-get proc :authenticated)
    (if (and (string-match "-auth \\(.*?\\)\n" string)
	     (equal (match-string 1 string) (process-get proc :auth-key)))
	(progn
	  (setq string (substring string (match-end 0)))
	  (process-put proc :authenticated t)
	  (server-log "Authentication successful" proc))
      (server-log "Authentication failed" proc)
      (server-send-string
       proc (concat "-error " (server-quote-arg "Authentication failed")))
      (delete-process proc)
      ;; We return immediately
      (return-from server-process-filter)))
  (when (> (recursion-depth) 0)
    ;; We're inside a minibuffer already, so if the emacs-client is trying
    ;; to open a frame on a new display, we might end up with an unusable
    ;; frame because input from that display will be blocked (until exiting
    ;; the minibuffer).  Better exit this minibuffer right away.
    ;; Similarly with recursive-edits such as the splash screen.
    (process-put proc :previous-string string)
    (run-with-timer 0 nil (lexical-let ((proc proc))
			    (lambda () (server-process-filter proc ""))))
    (top-level))
  (let ((prev (process-get proc 'previous-string)))
    (when prev
      (setq string (concat prev string))
      (process-put proc 'previous-string nil)))
  (condition-case err
      (progn
	(server-add-client proc)
	;; If the input is multiple lines,
	;; process each line individually.
	(while (string-match "\n" string)
	  (let ((request (substring string 0 (match-beginning 0)))
		(coding-system (and default-enable-multibyte-characters
				    (or file-name-coding-system
					default-file-name-coding-system)))
		(client (server-client proc))
		current-frame
		nowait ; t if emacsclient does not want to wait for us.
		frame ; The frame that was opened for the client (if any).
		display		     ; Open the frame on this display.
		dontkill       ; t if the client should not be killed.
		env
		dir
		(files nil)
		(lineno 1)
		(columnno 0))
	    ;; Remove this line from STRING.
	    (setq string (substring string (match-end 0)))
	    (while (string-match " *[^ ]* " request)
	      (let ((arg (substring request (match-beginning 0) (1- (match-end 0)))))
		(setq request (substring request (match-end 0)))
		(cond
		 ;; -version CLIENT-VERSION:
		 ;; Check version numbers, signal an error if there is a mismatch.
		 ((and (equal "-version" arg)
		       (string-match "\\([0-9.]+\\) " request))
		  (let* ((client-version (match-string 1 request))
			 (truncated-emacs-version
			  (substring emacs-version 0 (length client-version))))
		    (setq request (substring request (match-end 0)))
		    (if (equal client-version truncated-emacs-version)
			(progn
			  (server-send-string proc "-good-version \n")
			  (server-client-set client 'version client-version))
		      (error (concat "Version mismatch: Emacs is "
				     truncated-emacs-version
				     ", emacsclient is " client-version)))))

		 ;; -nowait:  Emacsclient won't wait for a result.
		 ((equal "-nowait" arg) (setq nowait t))

		 ;; -current-frame:  Don't create frames.
		 ((equal "-current-frame" arg) (setq current-frame t))

		 ;; -display DISPLAY:
		 ;; Open X frames on the given display instead of the default.
		 ((and (equal "-display" arg) (string-match "\\([^ ]*\\) " request))
		  (setq display (match-string 1 request)
			request (substring request (match-end 0))))

		 ;; -window-system:  Open a new X frame.
		 ((equal "-window-system" arg)
		  (unless (server-client-get client 'version)
		    (error "Protocol error; make sure to use the correct version of emacsclient"))
		  (unless current-frame
		    (if (fboundp 'x-create-frame)
			(let ((params (if nowait
					  ;; Flag frame as client-created, but use a dummy client.
					  ;; This will prevent the frame from being deleted when
					  ;; emacsclient quits while also preventing
					  ;; `server-save-buffers-kill-terminal' from unexpectedly
					  ;; killing emacs on that frame.
					  (list (cons 'client 'nowait) (cons 'environment env))
					(list (cons 'client proc) (cons 'environment env)))))
			  (setq frame (make-frame-on-display
				       (or display
					   (frame-parameter nil 'display)
					   (getenv "DISPLAY")
					   (error "Please specify display"))
				       params))
			  (server-log (format "%s created" frame) proc)
			  ;; XXX We need to ensure the parameters are
			  ;; really set because Emacs forgets unhandled
			  ;; initialization parameters for X frames at
			  ;; the moment.
			  (modify-frame-parameters frame params)
			  (select-frame frame)
			  (server-client-set client 'frame frame)
			  (server-client-set client 'terminal (frame-terminal frame))

			  ;; Display *scratch* by default.
			  (switch-to-buffer (get-buffer-create "*scratch*") 'norecord)
			  (if dir (setq default-directory dir))

			  (setq dontkill t))
		      ;; This emacs does not support X.
		      (server-log "Window system unsupported" proc)
		      (server-send-string proc "-window-system-unsupported \n")
		      (setq dontkill t))))

		 ;; -resume:  Resume a suspended tty frame.
		 ((equal "-resume" arg)
		  (let ((terminal (server-client-get client 'terminal)))
		    (setq dontkill t)
		    (when (eq (terminal-live-p terminal) t)
		      (resume-tty terminal))))

		 ;; -suspend:  Suspend the client's frame.  (In case we
		 ;; get out of sync, and a C-z sends a SIGTSTP to
		 ;; emacsclient.)
		 ((equal "-suspend" arg)
		  (let ((terminal (server-client-get client 'terminal)))
		    (setq dontkill t)
		    (when (eq (terminal-live-p terminal) t)
		      (suspend-tty terminal))))

		 ;; -ignore COMMENT:  Noop; useful for debugging emacsclient.
		 ;; (The given comment appears in the server log.)
		 ((and (equal "-ignore" arg) (string-match "\\([^ ]*\\) " request))
		  (setq dontkill t
			request (substring request (match-end 0))))

		 ;; -tty DEVICE-NAME TYPE:  Open a new tty frame at the client.
		 ((and (equal "-tty" arg) (string-match "\\([^ ]*\\) \\([^ ]*\\) " request))
		  (let ((tty (server-unquote-arg (match-string 1 request)))
			(type (server-unquote-arg (match-string 2 request))))
		    (setq request (substring request (match-end 0)))
		    (unless (server-client-get client 'version)
		      (error "Protocol error; make sure you use the correct version of emacsclient"))
		    (unless current-frame
		      (server-with-environment env
			  '("LANG" "LC_CTYPE" "LC_ALL"
			    ;; For tgetent(3); list according to ncurses(3).
			    "BAUDRATE" "COLUMNS" "ESCDELAY" "HOME" "LINES"
			    "NCURSES_ASSUMED_COLORS" "NCURSES_NO_PADDING"
			    "NCURSES_NO_SETBUF" "TERM" "TERMCAP" "TERMINFO"
			    "TERMINFO_DIRS" "TERMPATH")
			(setq frame (make-frame-on-tty tty type
						       ;; Ignore nowait here; we always need to clean
						       ;; up opened ttys when the client dies.
						       `((client . ,proc)
							 (environment . ,env)))))
		      (select-frame frame)
		      (server-client-set client 'frame frame)
		      (server-client-set client 'tty (terminal-name frame))
		      (server-client-set client 'terminal (frame-terminal frame))

		      ;; Display *scratch* by default.
		      (switch-to-buffer (get-buffer-create "*scratch*") 'norecord)
		      (if dir (setq default-directory dir))

		      ;; Reply with our pid.
		      (server-send-string proc (concat "-emacs-pid " (number-to-string (emacs-pid)) "\n"))
		      (setq dontkill t))))

		 ;; -position LINE:  Go to the given line in the next file.
		 ((and (equal "-position" arg) (string-match "\\(\\+[0-9]+\\) " request))
		  (setq lineno (string-to-number (substring (match-string 1 request) 1))
			request (substring request (match-end 0))))

		 ;; -position LINE:COLUMN:  Set point to the given position in the next file.
		 ((and (equal "-position" arg) (string-match "\\+\\([0-9]+\\):\\([0-9]+\\) " request))
		  (setq lineno (string-to-number (match-string 1 request))
			columnno (string-to-number (match-string 2 request))
			request (substring request (match-end 0))))

		 ;; -file FILENAME:  Load the given file.
		 ((and (equal "-file" arg) (string-match "\\([^ ]+\\) " request))
		  (let ((file (server-unquote-arg (match-string 1 request))))
		    (setq request (substring request (match-end 0)))
		    (if coding-system
			(setq file (decode-coding-string file coding-system)))
		    (setq file (command-line-normalize-file-name file))
		    (push (list file lineno columnno) files)
		    (server-log (format "New file: %s (%d:%d)" file lineno columnno) proc))
		  (setq lineno 1
			columnno 0))

		 ;; -eval EXPR:  Evaluate a Lisp expression.
		 ((and (equal "-eval" arg) (string-match "\\([^ ]+\\) " request))
		  (let ((expr (server-unquote-arg (match-string 1 request))))
		    (setq request (substring request (match-end 0)))
		    (if coding-system
			(setq expr (decode-coding-string expr coding-system)))
		    (let ((v (eval (car (read-from-string expr)))))
		      (when (and (not frame) v)
			(with-temp-buffer
			  (let ((standard-output (current-buffer)))
			    (pp v)
			    (server-send-string
			     proc (format "-print %s\n"
					  (server-quote-arg
					   (buffer-substring-no-properties (point-min)
									   (point-max)))))))))
		    (setq lineno 1
			  columnno 0)))

		 ;; -env NAME=VALUE:  An environment variable.
		 ((and (equal "-env" arg) (string-match "\\([^ ]+\\) " request))
		  (let ((var (server-unquote-arg (match-string 1 request))))
		    ;; XXX Variables should be encoded as in getenv/setenv.
		    (setq request (substring request (match-end 0)))
		    (setq env (cons var env))))

		 ;; -dir DIRNAME:  The cwd of the emacsclient process.
		 ((and (equal "-dir" arg) (string-match "\\([^ ]+\\) " request))
		  (setq dir (server-unquote-arg (match-string 1 request)))
		  (setq request (substring request (match-end 0)))
		  (if coding-system
		      (setq dir (decode-coding-string dir coding-system)))
		  (setq dir (command-line-normalize-file-name dir)))

		 ;; Unknown command.
		 (t (error "Unknown command: %s" arg)))))

	    (let (buffers)
	      (when files
		(run-hooks 'pre-command-hook)
		(setq buffers (server-visit-files files client nowait))
		(run-hooks 'post-command-hook))

	      (when frame
		(with-selected-frame frame
		  (display-startup-echo-area-message)
		  (unless inhibit-splash-screen
		    (condition-case err
			;; This looks scary because `fancy-splash-screens'
			;; will call `recursive-edit' from a process filter.
			;; However, that should be safe to do now.
			(display-splash-screen t)
		      ;; `recursive-edit' will throw an error if Emacs is
		      ;; already doing a recursive edit elsewhere.  Catch it
		      ;; here so that we can finish normally.
		      (error nil)))))

	      ;; Delete the client if necessary.
	      (cond
	       (nowait
		;; Client requested nowait; return immediately.
		(server-log "Close nowait client" proc)
		(server-delete-client proc))
	       ((and (not dontkill) (null buffers))
		;; This client is empty; get rid of it immediately.
		(server-log "Close empty client" proc)
		(server-delete-client proc)))
	      (cond
	       ((or isearch-mode (minibufferp))
		nil)
	       ((and frame (null buffers))
		(message "%s" (substitute-command-keys
			       "When done with this frame, type \\[delete-frame]")))
	       ((not (null buffers))
		(server-switch-buffer (car buffers))
		(run-hooks 'server-switch-hook)
		(unless nowait
		  (message "%s" (substitute-command-keys
				 "When done with a buffer, type \\[server-edit]"))))))))

	;; Save for later any partial line that remains.
	(when (> (length string) 0)
	  (process-put proc 'previous-string string)))
    ;; condition-case
    (error (ignore-errors
	     (server-send-string
	      proc (concat "-error " (server-quote-arg (error-message-string err))))
	     (setq string "")
	     (server-log (error-message-string err) proc)
	     (delete-process proc)))))

(defun server-goto-line-column (file-line-col)
  "Move point to the position indicated in FILE-LINE-COL.
FILE-LINE-COL should be a three-element list as described in
`server-visit-files'."
  (goto-line (nth 1 file-line-col))
  (let ((column-number (nth 2 file-line-col)))
    (if (> column-number 0)
	(move-to-column (1- column-number)))))

(defun server-visit-files (files client &optional nowait)
  "Find FILES and return a list of buffers created.
FILES is an alist whose elements are (FILENAME LINENUMBER COLUMNNUMBER).
CLIENT is the client that requested this operation.
NOWAIT non-nil means this client is not waiting for the results,
so don't mark these buffers specially, just visit them normally."
  ;; Bind last-nonmenu-event to force use of keyboard, not mouse, for queries.
  (let ((last-nonmenu-event t) client-record)
    ;; Restore the current buffer afterward, but not using save-excursion,
    ;; because we don't want to save point in this buffer
    ;; if it happens to be one of those specified by the server.
    (save-current-buffer
      (dolist (file files)
	;; If there is an existing buffer modified or the file is
	;; modified, revert it.  If there is an existing buffer with
	;; deleted file, offer to write it.
	(let* ((minibuffer-auto-raise (or server-raise-frame
					  minibuffer-auto-raise))
	       (filen (car file))
	       (obuf (get-file-buffer filen)))
	  (add-to-history 'file-name-history filen)
	  (if (and obuf (set-buffer obuf))
	      (progn
		(cond ((file-exists-p filen)
		       (when (not (verify-visited-file-modtime obuf))
			 (revert-buffer t nil)))
		      (t
		       (when (y-or-n-p
			      (concat "File no longer exists: " filen
				      ", write buffer to file? "))
			 (write-file filen))))
		(unless server-buffer-clients
		  (setq server-existing-buffer t))
		(server-goto-line-column file))
	    (set-buffer (find-file-noselect filen))
	    (server-goto-line-column file)
	    (run-hooks 'server-visit-hook)))
	(unless nowait
	  ;; When the buffer is killed, inform the clients.
	  (add-hook 'kill-buffer-hook 'server-kill-buffer nil t)
	  (push (car client) server-buffer-clients))
	(push (current-buffer) client-record)))
    (unless nowait
      (server-client-set
       client 'buffers
       (nconc (server-client-get client 'buffers) client-record)))
    client-record))

(defun server-buffer-done (buffer &optional for-killing)
  "Mark BUFFER as \"done\" for its client(s).
This buries the buffer, then returns a list of the form (NEXT-BUFFER KILLED).
NEXT-BUFFER is another server buffer, as a suggestion for what to select next,
or nil.  KILLED is t if we killed BUFFER (typically, because it was visiting
a temp file).
FOR-KILLING if non-nil indicates that we are called from `kill-buffer'."
  (let ((next-buffer nil)
	(killed nil))
    (dolist (client server-clients)
      (let ((buffers (server-client-get client 'buffers)))
	(or next-buffer
	    (setq next-buffer (nth 1 (memq buffer buffers))))
	(when buffers			; Ignore bufferless clients.
	  (setq buffers (delq buffer buffers))
	  ;; Delete all dead buffers from CLIENT.
	  (dolist (b buffers)
	    (and (bufferp b)
		 (not (buffer-live-p b))
		 (setq buffers (delq b buffers))))
	  (server-client-set client 'buffers buffers)
	  ;; If client now has no pending buffers,
	  ;; tell it that it is done, and forget it entirely.
	  (unless buffers
	    (server-log "Close" client)
	    (server-delete-client client)))))
    (when (and (bufferp buffer) (buffer-name buffer))
      ;; We may or may not kill this buffer;
      ;; if we do, do not call server-buffer-done recursively
      ;; from kill-buffer-hook.
      (let ((server-kill-buffer-running t))
	(with-current-buffer buffer
	  (setq server-buffer-clients nil)
	  (run-hooks 'server-done-hook))
	;; Notice whether server-done-hook killed the buffer.
	(if (null (buffer-name buffer))
	    (setq killed t)
	  ;; Don't bother killing or burying the buffer
	  ;; when we are called from kill-buffer.
	  (unless for-killing
	    (when (and (not killed)
		       server-kill-new-buffers
		       (with-current-buffer buffer
			 (not server-existing-buffer)))
	      (setq killed t)
	      (bury-buffer buffer)
	      (kill-buffer buffer))
	    (unless killed
	      (if (server-temp-file-p buffer)
		  (progn
		    (kill-buffer buffer)
		    (setq killed t))
		(bury-buffer buffer)))))))
    (list next-buffer killed)))

(defun server-temp-file-p (&optional buffer)
  "Return non-nil if BUFFER contains a file considered temporary.
These are files whose names suggest they are repeatedly
reused to pass information to another program.

The variable `server-temp-file-regexp' controls which filenames
are considered temporary."
  (and (buffer-file-name buffer)
       (string-match server-temp-file-regexp (buffer-file-name buffer))))

(defun server-done ()
  "Offer to save current buffer, mark it as \"done\" for clients.
This kills or buries the buffer, then returns a list
of the form (NEXT-BUFFER KILLED).  NEXT-BUFFER is another server buffer,
as a suggestion for what to select next, or nil.
KILLED is t if we killed BUFFER, which happens if it was created
specifically for the clients and did not exist before their request for it."
  (when server-buffer-clients
    (if (server-temp-file-p)
	;; For a temp file, save, and do make a non-numeric backup
	;; (unless make-backup-files is nil).
	(let ((version-control nil)
	      (buffer-backed-up nil))
	  (save-buffer))
      (when (and (buffer-modified-p)
		 buffer-file-name
		 (y-or-n-p (concat "Save file " buffer-file-name "? ")))
	(save-buffer)))
    (server-buffer-done (current-buffer))))

;; Ask before killing a server buffer.
;; It was suggested to release its client instead,
;; but I think that is dangerous--the client would proceed
;; using whatever is on disk in that file. -- rms.
(defun server-kill-buffer-query-function ()
  "Ask before killing a server buffer."
  (or (not server-buffer-clients)
      (let ((res t))
	(dolist (proc server-buffer-clients res)
	  (let ((client (server-client proc)))
	    (when (and client (eq (process-status proc) 'open))
	      (setq res nil)))))
      (yes-or-no-p (format "Buffer `%s' still has clients; kill it? "
			   (buffer-name (current-buffer))))))

(defun server-kill-emacs-query-function ()
  "Ask before exiting Emacs it has live clients."
  (or (not server-clients)
      (let (live-client)
	(dolist (client server-clients live-client)
	  (when (memq t (mapcar 'buffer-live-p (server-client-get
						client 'buffers)))
	    (setq live-client t))))
      (yes-or-no-p "This Emacs session has clients; exit anyway? ")))

(defvar server-kill-buffer-running nil
  "Non-nil while `server-kill-buffer' or `server-buffer-done' is running.")

(defun server-kill-buffer ()
  "Remove the current buffer from its clients' buffer list.
Designed to be added to `kill-buffer-hook'."
  ;; Prevent infinite recursion if user has made server-done-hook
  ;; call kill-buffer.
  (or server-kill-buffer-running
      (and server-buffer-clients
	   (let ((server-kill-buffer-running t))
	     (when server-process
	       (server-buffer-done (current-buffer) t))))))

(defun server-edit (&optional arg)
  "Switch to next server editing buffer; say \"Done\" for current buffer.
If a server buffer is current, it is marked \"done\" and optionally saved.
The buffer is also killed if it did not exist before the clients asked for it.
When all of a client's buffers are marked as \"done\", the client is notified.

Temporary files such as MH <draft> files are always saved and backed up,
no questions asked.  (The variable `make-backup-files', if nil, still
inhibits a backup; you can set it locally in a particular buffer to
prevent a backup for it.)  The variable `server-temp-file-regexp' controls
which filenames are considered temporary.

If invoked with a prefix argument, or if there is no server process running,
starts server process and that is all.  Invoked by \\[server-edit]."
  (interactive "P")
  (cond
    ((or arg
         (not server-process)
         (memq (process-status server-process) '(signal exit)))
     (server-mode 1))
    (server-clients (apply 'server-switch-buffer (server-done)))
    (t (message "No server editing buffers exist"))))

(defun server-switch-buffer (&optional next-buffer killed-one)
  "Switch to another buffer, preferably one that has a client.
Arg NEXT-BUFFER is a suggestion; if it is a live buffer, use it.

KILLED-ONE is t in a recursive call if we have already killed one
temp-file server buffer.  This means we should avoid the final
\"switch to some other buffer\" since we've already effectively
done that."
  (if (null next-buffer)
      (progn
	(let ((rest server-clients))
	  (while (and rest (not next-buffer))
	    (let ((client (car rest)))
	      ;; Only look at frameless clients.
	      (when (not (server-client-get client 'frame))
		(setq next-buffer (car (server-client-get client 'buffers))))
	      (setq rest (cdr rest)))))
	(and next-buffer (server-switch-buffer next-buffer killed-one))
	(unless (or next-buffer killed-one (window-dedicated-p (selected-window)))
	  ;; (switch-to-buffer (other-buffer))
	  (message "No server buffers remain to edit")))
    (if (not (buffer-live-p next-buffer))
	;; If NEXT-BUFFER is a dead buffer, remove the server records for it
	;; and try the next surviving server buffer.
	(apply 'server-switch-buffer (server-buffer-done next-buffer))
      ;; OK, we know next-buffer is live, let's display and select it.
      (if (functionp server-window)
	  (funcall server-window next-buffer)
	(let ((win (get-buffer-window next-buffer 0)))
	  (if (and win (not server-window))
	      ;; The buffer is already displayed: just reuse the window.
              (progn
                (select-window win)
                (set-buffer next-buffer))
	    ;; Otherwise, let's find an appropriate window.
	    (cond ((and (windowp server-window)
			(window-live-p server-window))
		   (select-window server-window))
		  ((framep server-window)
		   (unless (frame-live-p server-window)
		     (setq server-window (make-frame)))
		   (select-window (frame-selected-window server-window))))
	    (when (window-minibuffer-p (selected-window))
	      (select-window (next-window nil 'nomini 0)))
	    ;; Move to a non-dedicated window, if we have one.
	    (when (window-dedicated-p (selected-window))
	      (select-window
	       (get-window-with-predicate
		(lambda (w)
		  (and (not (window-dedicated-p w))
		       (equal (frame-terminal (window-frame w))
			      (frame-terminal (selected-frame)))))
		'nomini 'visible (selected-window))))
	    (condition-case nil
		(switch-to-buffer next-buffer)
	      ;; After all the above, we might still have ended up with
	      ;; a minibuffer/dedicated-window (if there's no other).
	      (error (pop-to-buffer next-buffer)))))))
    (when server-raise-frame
      (select-frame-set-input-focus (window-frame (selected-window))))))

;;;###autoload
(defun server-save-buffers-kill-terminal (proc &optional arg)
  "Offer to save each buffer, then kill PROC.

With prefix arg, silently save all file-visiting buffers, then kill.

If emacsclient was started with a list of filenames to edit, then
only these files will be asked to be saved."
  (let ((buffers (server-client-get proc 'buffers)))
    ;; If client is bufferless, emulate a normal Emacs session
    ;; exit and offer to save all buffers.  Otherwise, offer to
    ;; save only the buffers belonging to the client.
    (save-some-buffers arg
		       (if buffers
			   (lambda () (memq (current-buffer) buffers))
			 t))
    (server-delete-client proc)))

(define-key ctl-x-map "#" 'server-edit)

(defun server-unload-hook ()
  "Unload the server library."
  (server-mode -1)
  (remove-hook 'suspend-tty-functions 'server-handle-suspend-tty)
  (remove-hook 'delete-frame-functions 'server-handle-delete-frame)
  (remove-hook 'kill-buffer-query-functions 'server-kill-buffer-query-function)
  (remove-hook 'kill-emacs-query-functions 'server-kill-emacs-query-function)
  (remove-hook 'kill-buffer-hook 'server-kill-buffer))

(add-hook 'kill-emacs-hook (lambda () (server-mode -1))) ;Cleanup upon exit.
(add-hook 'server-unload-hook 'server-unload-hook)

(provide 'server)

;; arch-tag: 1f7ecb42-f00a-49f8-906d-61995d84c8d6
;;; server.el ends here
