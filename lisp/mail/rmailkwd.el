;;; rmailkwd.el --- part of the "RMAIL" mail reader for Emacs

;; Copyright (C) 1985, 1988, 1994, 2001, 2002, 2003, 2004, 2005, 2006,
;;   2007, 2008, 2009  Free Software Foundation, Inc.

;; Maintainer: FSF
;; Keywords: mail

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:

(require 'rmail)

;; Global to all RMAIL buffers.  It exists primarily for the sake of
;; completion.  It is better to use strings with the label functions
;; and let them worry about making the label.

(defvar rmail-label-obarray (make-vector 47 0))

(mapc (function (lambda (s) (intern s rmail-label-obarray)))
      '("deleted" "answered" "filed" "forwarded" "unseen" "edited"
	"resent"))

(defun rmail-make-label (s)
  (intern (downcase s) rmail-label-obarray))

;;;###autoload
(defun rmail-add-label (string)
  "Add LABEL to labels associated with current RMAIL message.
Performs completion over known labels when reading."
  (interactive (list (rmail-read-label "Add label")))
  (rmail-set-label string t))

;;;###autoload
(defun rmail-kill-label (string)
  "Remove LABEL from labels associated with current RMAIL message.
Performs completion over known labels when reading."
  (interactive (list (rmail-read-label "Remove label")))
  (rmail-set-label string nil))

;;;###autoload
(defun rmail-read-label (prompt)
  (let ((result
	 (completing-read (concat prompt
				  (if rmail-last-label
				      (concat " (default "
					      (symbol-name rmail-last-label)
					      "): ")
				    ": "))
			  rmail-label-obarray
			  nil
			  nil)))
    (if (string= result "")
	rmail-last-label
      (setq rmail-last-label (rmail-make-label result)))))

(defun rmail-set-label (label state &optional msg)
  "Set LABEL as present or absent according to STATE in message MSG."
  (with-current-buffer rmail-buffer
    (rmail-maybe-set-message-counters)
    (if (not msg) (setq msg rmail-current-message))
    ;; Force recalculation of summary for this message.
    (aset rmail-summary-vector (1- msg) nil)
    (let (attr-index)
      ;; Is this label an attribute?
      (dotimes (i (length rmail-attr-array))
	(if (string= (cadr (aref rmail-attr-array i)) label)
	    (setq attr-index i)))
      (if attr-index
	  ;; If so, set it as an attribute.
	  (rmail-set-attribute attr-index state msg)
	;; Is this keyword already present in msg's keyword list?
	(let* ((header (rmail-get-header rmail-keyword-header msg))
	       (regexp (concat ", " (regexp-quote (symbol-name label)) ","))
	       (present (string-match regexp (concat ", " header ","))))
	  ;; If current state is not correct,
	  (unless (eq present state)
	    ;; either add it or delete it.
	    (rmail-set-header
	     rmail-keyword-header msg
	     (if state
		 ;; Add this keyword at the end.
		 (if (and header (not (string= header "")))
		     (concat header ", " (symbol-name label))
		   (symbol-name label))
	       ;; Delete this keyword.
	       (let ((before (substring header 0
					(max 0 (- (match-beginning 0) 2))))
		     (after (substring header
				       (min (length header)
					    (- (match-end 0) 1)))))
		 (cond ((string= before "")
			after)
		       ((string= after "")
			before)
		       (t (concat before ", " after)))))))))
      (if (= msg rmail-current-message)
	  (rmail-display-labels)))))

;; Motion on messages with keywords.

;;;###autoload
(defun rmail-previous-labeled-message (n labels)
  "Show previous message with one of the labels LABELS.
LABELS should be a comma-separated list of label names.
If LABELS is empty, the last set of labels specified is used.
With prefix argument N moves backward N messages with these labels."
  (interactive "p\nsMove to previous msg with labels: ")
  (rmail-next-labeled-message (- n) labels))

(declare-function mail-comma-list-regexp "mail-utils" (labels))

;;;###autoload
(defun rmail-next-labeled-message (n labels)
  "Show next message with one of the labels LABELS.
LABELS should be a comma-separated list of label names.
If LABELS is empty, the last set of labels specified is used.
With prefix argument N moves forward N messages with these labels."
  (interactive "p\nsMove to next msg with labels: ")
  (if (string= labels "")
      (setq labels rmail-last-multi-labels))
  (or labels
      (error "No labels to find have been specified previously"))
  (set-buffer rmail-buffer)
  (setq rmail-last-multi-labels labels)
  (rmail-maybe-set-message-counters)
  (let ((lastwin rmail-current-message)
	(current rmail-current-message)
	(regexp (concat ", ?\\("
			(mail-comma-list-regexp labels)
			"\\),")))
    (while (and (> n 0) (< current rmail-total-messages))
      (setq current (1+ current))
      (if (string-match regexp (rmail-get-labels current))
	  (setq lastwin current n (1- n))))
    (while (and (< n 0) (> current 1))
      (setq current (1- current))
      (if (string-match regexp (rmail-get-labels current))
	  (setq lastwin current n (1+ n))))
    (if (< n 0)
	(error "No previous message with labels %s" labels)
      (if (> n 0)
	  (error "No following message with labels %s" labels)
	(rmail-show-message lastwin)))))

(provide 'rmailkwd)

;; Local Variables:
;; change-log-default-name: "ChangeLog.rmail"
;; End:

;; arch-tag: 1149979c-8e47-4333-9629-cf3dc887a6a7
;;; rmailkwd.el ends here
