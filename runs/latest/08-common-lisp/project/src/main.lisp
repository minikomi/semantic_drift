(in-package #:todo-summary)

(defstruct summary
  user-id
  (completed 0 :type integer)
  (missed 0 :type integer))

(define-condition app-error (error)
  ((message :initarg :message :reader app-error-message))
  (:report (lambda (condition stream)
             (princ (app-error-message condition) stream))))

(defun fail-with (message)
  (error 'app-error :message message))

(defun decode-json (body)
  (handler-case
      (yason:parse body
                   :object-as :alist
                   :object-key-fn #'identity
                   :json-arrays-as-vectors t
                   :json-booleans-as-symbols t
                   :json-nulls-as-keyword t)
    (error (err)
      (fail-with (princ-to-string err)))))

(defun json-key (value)
  (let ((*read-default-float-format* 'double-float))
    (with-output-to-string (out)
      (yason:encode value out))))

(defun finite-float-p (value)
  #+sbcl (not (or (sb-ext:float-nan-p value) (sb-ext:float-infinity-p value)))
  #-sbcl (declare (ignore value))
  #-sbcl t)

(defun integer-valued-float-p (value)
  (and (floatp value)
       (finite-float-p value)
       (= value (fround value))))

(defun display-number (value)
  (cond
    ((integerp value) (format nil "~D" value))
    ((integer-valued-float-p value) (format nil "~D" (round value)))
    (t (cpp-default-double-string (coerce value 'double-float)))))

(defun display-value (value)
  (cond
    ((stringp value) value)
    ((numberp value) (display-number value))
    ((eq value 'yason:true) "true")
    ((eq value 'yason:false) "false")
    ((eq value 'yason:null) "")
    (t (json-key value))))

(defun as-boolean (value)
  (or (eq value 'yason:true)
      (and (stringp value) (string= value "true"))
      (and (numberp value) (= value 1))))

(defun as-text (value)
  (display-value value))

(defun required (todo field)
  (if (listp todo)
      (let ((cell (assoc field todo :test #'string=)))
        (if cell
            (cdr cell)
            (fail-with (format nil "key '~A' not found" field))))
      (fail-with (format nil "key '~A' not found" field))))

(defun parse-error-message (value)
  (format nil "parsing time \"~A\" as \"2006-01-02\": cannot parse \"~A\" as \"2006\""
          value value))

(defun digit-char-at-p (value index)
  (or (= index 4)
      (= index 7)
      (digit-char-p (char value index))))

(defun parse-date-only-in-local-time (value)
  (let ((shape-ok (and (= (length value) 10)
                       (char= (char value 4) #\-)
                       (char= (char value 7) #\-)
                       (loop for i from 0 below 10
                             always (digit-char-at-p value i)))))
    (unless shape-ok
      (fail-with (parse-error-message value)))
    (let ((year (parse-integer value :start 0 :end 4))
          (month (parse-integer value :start 5 :end 7))
          (day (parse-integer value :start 8 :end 10)))
      (handler-case
          (encode-universal-time 0 0 0 day month year 0)
        (error ()
          (fail-with (parse-error-message value)))))))

(defun today-local ()
  (multiple-value-bind (second minute hour date month year)
      (decode-universal-time (get-universal-time))
    (declare (ignore second minute hour))
    (encode-universal-time 0 0 0 date month year 0)))

(defun fold-todos (today todos)
  (unless (vectorp todos)
    (fail-with "expected JSON array"))
  (let ((by-user (make-hash-table :test #'equal)))
    (loop for todo across todos do
      (let* ((user-id (required todo "userId"))
             (completed (required todo "completed"))
             (due-date (required todo "dueDate"))
             (key (json-key user-id))
             (current (or (gethash key by-user)
                          (setf (gethash key by-user)
                                (make-summary :user-id user-id)))))
        (if (as-boolean completed)
            (incf (summary-completed current))
            (let ((due (parse-date-only-in-local-time (as-text due-date))))
              (when (< due today)
                (incf (summary-missed current)))))))
    (loop for value being the hash-values of by-user collect value)))

(defun value-rank (value)
  (cond
    ((eq value 'yason:null) 0)
    ((eq value 'yason:false) 1)
    ((eq value 'yason:true) 1)
    ((numberp value) 2)
    ((stringp value) 3)
    ((vectorp value) 4)
    ((listp value) 5)
    (t 6)))

(defun compare-user-id< (a b)
  (cond
    ((and (numberp a) (numberp b)) (< (coerce a 'double-float) (coerce b 'double-float)))
    ((and (stringp a) (stringp b)) (string< a b))
    ((and (or (eq a 'yason:true) (eq a 'yason:false))
          (or (eq b 'yason:true) (eq b 'yason:false)))
     (and (eq a 'yason:false) (eq b 'yason:true)))
    (t (string< (json-key a) (json-key b)))))

(defun summary< (a b)
  (cond
    ((/= (summary-completed a) (summary-completed b))
     (> (summary-completed a) (summary-completed b)))
    ((/= (summary-missed a) (summary-missed b))
     (> (summary-missed a) (summary-missed b)))
    (t (compare-user-id< (summary-user-id a) (summary-user-id b)))))

(defun pad-right (width value)
  (concatenate 'string value (make-string (max 0 (- width (length value))) :initial-element #\Space)))

(defun print-row (row)
  (format t "~A ~A ~D~%"
          (pad-right 5 (display-value (summary-user-id row)))
          (pad-right 10 (format nil "~D" (summary-completed row)))
          (summary-missed row)))

(defun http-get (url)
  (handler-case
      (multiple-value-bind (body status headers uri stream must-close reason)
          (dex:get url :connect-timeout 10 :read-timeout 10 :force-binary nil)
        (declare (ignore headers uri stream must-close))
        (values body status reason))
    (dex:http-request-failed (err)
      (values (dex:response-body err)
              (dex:response-status err)
              (status-reason-phrase (dex:response-status err))))))

(defun status-reason-phrase (status)
  (cdr (assoc status
              '((400 . "Bad Request")
                (401 . "Unauthorized")
                (402 . "Payment Required")
                (403 . "Forbidden")
                (404 . "Not Found")
                (405 . "Method Not Allowed")
                (406 . "Not Acceptable")
                (407 . "Proxy Authentication Required")
                (408 . "Request Timeout")
                (409 . "Conflict")
                (410 . "Gone")
                (411 . "Length Required")
                (412 . "Precondition Failed")
                (413 . "Payload Too Large")
                (414 . "URI Too Long")
                (415 . "Unsupported Media Type")
                (416 . "Range Not Satisfiable")
                (417 . "Expectation Failed")
                (421 . "Misdirected Request")
                (426 . "Upgrade Required")
                (429 . "Too Many Requests")
                (500 . "Internal Server Error")
                (501 . "Not Implemented")
                (502 . "Bad Gateway")
                (503 . "Service Unavailable")
                (504 . "Gateway Timeout")
                (505 . "HTTP Version Not Supported")))))

(defun run (url)
  (multiple-value-bind (body status reason) (http-get url)
    (when (or (< status 200) (>= status 300))
      (fail-with (format nil "bad status: ~D~@[ ~A~]" status reason)))
    (let* ((todos (decode-json body))
           (today (today-local))
           (rows (sort (fold-todos today todos) #'summary<)))
      (format t "USER  COMPLETED  MISSED~%")
      (dolist (row rows)
        (print-row row)))))

(defun argv ()
  (let ((args (uiop:command-line-arguments)))
    (if (and args (string= (first args) "--"))
        (rest args)
        args)))

(defun main ()
  (handler-case
      (let ((args (argv)))
        (if (= (length args) 1)
            (run (first args))
            (progn
              (format *error-output* "usage: ~A <todos-url>~%" (or (first (argv)) "todo-summary"))
              (uiop:quit 1))))
    (app-error (err)
      (format *error-output* "~A~%" (app-error-message err))
      (uiop:quit 1))
    (error (err)
      (format *error-output* "~A~%" err)
      (uiop:quit 1))))
