(cl:in-package :cl-user)

(require :asdf)
#+sbcl(require :sb-posix)

(ros:quicklisp :environment nil)

(unless (find-package :uiop)
  #+quicklisp(ql:quickload :uiop :silent t))

(unless (find-package :net.html.parser)
  #+quicklisp(ql:quickload :cl-html-parse :silent t))

(defpackage :ros.install
  (:use :cl)
  (:export :*build-hook*))

(in-package :ros.install)

(defvar *opts* nil)
(defvar *ros-path* nil)
(defvar *build-hook* nil)

#+sbcl
(defclass count-line-stream (sb-gray:fundamental-character-output-stream)
  ((base :initarg :base
         :initform *standard-output*
         :reader count-line-stream-base)
   (print-char :initarg :print-char
               :initform `((700 . line-number)(10 . #\.))
               :accessor count-line-stream-print-char)
   (count-char :initarg :count-char
                :initform #\NewLine
                :reader count-line-stream-count-char)
   (count :initform -1
          :accessor count-line-stream-count)))
#+sbcl
(defmethod sb-gray:stream-write-char ((stream count-line-stream) character)
  (when (char= character (count-line-stream-count-char stream))
    (loop
       :with count := (incf (count-line-stream-count stream))
       :with stream- := (count-line-stream-base stream)
       :for (mod . char) :in (count-line-stream-print-char stream)
       :when (zerop (mod count mod))
       :do (if (characterp char)
               (write-char char stream-)
               (funcall char stream))
       (force-output stream-))))

#+sbcl
(defun line-number (stream)
  (format (count-line-stream-base stream) "~&~6d " (count-line-stream-count stream)))

(defun uname ()
  (ros:roswell '("roswell-internal-use uname") :string t))

(defun uname-m ()
  (ros:roswell '("roswell-internal-use uname -m") :string t))

(defun which (cmd)
  (let ((result (ros:roswell (list "roswell-internal-use which" cmd) :string t)))
    (unless (zerop (length result))
      result)))

(defun date (&optional (universal-time (get-universal-time)))
  (multiple-value-bind (second minute hour date month year day daylight time-zone)
      (decode-universal-time universal-time)
    (format nil "~A ~A ~2A ~2,,,'0A:~2,,,'0A:~2,,,'0A ~3A~A ~A"
            (nth day '("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"))
            (nth month '("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))
            date hour minute second time-zone (if daylight "S" " ") year)))

(defun get-opt (item)
  (second (assoc item *opts* :test #'equal)))

(defun set-opt (item val)
  (let ((found (assoc item *opts* :test #'equal)))
    (if found
        (setf (second found) val)
        (push (list item val) *opts*))))

(defun save-opt (item val)
  (ros:roswell `("config" "set" ,item ,val)))

(defun homedir ()
  (make-pathname :defaults (ros:opt "homedir")))

;;end here from util/opts.c

(defvar *install-cmds* nil)
(defvar *help-cmds* nil)
(defvar *list-cmd* nil)

(defun installedp (argv)
  (and (probe-file (merge-pathnames (format nil "impls/~A/~A/~A/~A/" (uname-m) (uname) (getf argv :target) (get-opt "as")) (homedir))) t))

(defun install-running-p (argv)
  ;;TBD
  (declare (ignore argv))
  nil)

(defun setup-signal-handler (path)
  ;;TBD
  (declare (ignore path)))

(defun sh ()
  (or #+win32
      (unless (ros:getenv "MSYSCON")
	(format nil "~A" (sb-ext:native-namestring
			  (merge-pathnames (format nil "impls/~A/~A/msys~A/usr/bin/bash" (uname-m) (uname)
						   #+x86-64 "64" #-x86-64 "32") (homedir)))))
      (which "bash")
      "sh"))
#+win32
(defun mingw-namestring (path)
  (string-right-trim (format nil "~%")
                     (uiop:run-program `(,(sh) "-lc" ,(format nil "cd ~S;pwd" (uiop:native-namestring path)))
                                       :output :string)))

(defun start (argv)
  (ensure-directories-exist (homedir))
  #+win32
  (let* ((w (ros:opt "wargv0"))
         (a (ros:opt "argv0"))
         (path (uiop:native-namestring
                (make-pathname :type nil :name nil :defaults (if (zerop (length w)) a w)))))
    (ros:setenv "MSYSTEM" #+x86-64 "MINGW64" #-x86-64 "MINGW32")
    (ros:setenv "PATH" (format nil "~A;~A"(subseq path 0 (1- (length path))) (ros:getenv "PATH"))))
  (let ((target (getf argv :target))
        (version (getf argv :version)))
    (when (and (installedp argv) (not (get-opt "install.force")))
      (format t "~A/~A is already installed. Try (TBD) for the forced re-installation.~%"
              target version)
      (return-from start (cons nil argv)))
    (when (install-running-p argv)
      (format t "It seems there are another ongoing installation process for ~A/~A somewhere in the system.\n"
              target version)
      (return-from start (cons nil argv)))
    (ensure-directories-exist (merge-pathnames (format nil "tmp/~A-~A/" target version) (homedir)))
    (let ((p (merge-pathnames (format nil "tmp/~A-~A.lock" target version) (homedir))))
      (setup-signal-handler p)
      (with-open-file (o p :direction :probe :if-does-not-exist :create))))
  (cons t argv))

(defun download (uri file &key proxy)
  (declare (ignorable proxy))
  (ros:roswell `("roswell-internal-use" "download" ,uri ,file) :interactive nil))

(defun expand (archive dest &key verbose)
  (ros:roswell `(,(if verbose "-v" "")"roswell-internal-use tar" "-xf" ,archive "-C" ,dest)
               (or #-win32 :interactive nil) nil))

(defun setup (argv)
  (save-opt "default.lisp" (getf argv :target))
  (save-opt (format nil "~A.version" (getf argv :target)) (get-opt "as"))
  (cons t argv))

(defun install-script (from)
  (let ((to (ensure-directories-exist
             (make-pathname
              :defaults (merge-pathnames "bin/" (homedir))
              :name (pathname-name from)
              :type (unless (or #+unix (equalp (pathname-type from) "ros"))
                      (pathname-type from))))))
    (format *error-output* "~&~A~%" to)
    (uiop/stream:copy-file from to)
    ;; Experimented on 0.0.3.38 but it has some problem. see https://github.com/roswell/roswell/issues/53
    #+nil(if (equalp (pathname-type from) "ros")
             (ros:roswell `("build" ,from "-o" ,to) :interactive nil)
             (uiop/stream:copy-file from to))
    #+sbcl(sb-posix:chmod to #o700)))
