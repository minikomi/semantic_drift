(require :asdf)

(defstruct jnull)
(defstruct (jbool (:constructor make-jbool (value))) value)
(defstruct (jnum (:constructor make-jnum (raw value integerp))) raw value integerp)
(defstruct (jstr (:constructor make-jstr (value))) value)
(defstruct (jarray (:constructor make-jarray (values))) values)
(defstruct (jobject (:constructor make-jobject (pairs))) pairs)
(defstruct (summary (:constructor make-summary (user-id completed missed)))
  user-id completed missed)

(define-condition program-error-message (error)
  ((message :initarg :message :reader error-message)))

(defun fail (control &rest args)
  (error 'program-error-message :message (apply #'format nil control args)))

(defun whitespacep (ch)
  (and ch (find ch '(#\Space #\Tab #\Newline #\Return) :test #'char=)))

(defun skip-ws (text pos)
  (loop while (and (< pos (length text)) (whitespacep (char text pos)))
        do (incf pos)
        finally (return pos)))

(defun expect-char (text pos expected)
  (if (and (< pos (length text)) (char= (char text pos) expected))
      (1+ pos)
      (fail "unexpected character while parsing JSON")))

(defun hex-value (ch)
  (cond
    ((and (char>= ch #\0) (char<= ch #\9)) (- (char-code ch) (char-code #\0)))
    ((and (char>= ch #\a) (char<= ch #\f)) (+ 10 (- (char-code ch) (char-code #\a))))
    ((and (char>= ch #\A) (char<= ch #\F)) (+ 10 (- (char-code ch) (char-code #\A))))
    (t (fail "invalid unicode escape"))))

(defun parse-json-string (text pos)
  (setf pos (expect-char text pos #\"))
  (let ((out (make-string-output-stream)))
    (loop
      (when (>= pos (length text)) (fail "unterminated string"))
      (let ((ch (char text pos)))
        (incf pos)
        (cond
          ((char= ch #\")
           (return (values (get-output-stream-string out) pos)))
          ((char= ch #\\)
           (when (>= pos (length text)) (fail "unterminated escape"))
           (let ((esc (char text pos)))
             (incf pos)
             (case esc
               (#\" (write-char #\" out))
               (#\\ (write-char #\\ out))
               (#\/ (write-char #\/ out))
               (#\b (write-char (code-char 8) out))
               (#\f (write-char (code-char 12) out))
               (#\n (write-char #\Newline out))
               (#\r (write-char #\Return out))
               (#\t (write-char #\Tab out))
               (#\u
                (when (> (+ pos 4) (length text)) (fail "short unicode escape"))
                (let ((code 0))
                  (dotimes (i 4)
                    (setf code (+ (* code 16) (hex-value (char text (+ pos i))))))
                  (incf pos 4)
                  (write-char (code-char code) out)))
               (otherwise (fail "invalid escape")))))
          (t (write-char ch out)))))))

(defun number-char-p (ch)
  (and ch (or (digit-char-p ch) (find ch "+-.eE" :test #'char=))))

(defun parse-json-number (text pos)
  (let ((start pos))
    (loop while (and (< pos (length text)) (number-char-p (char text pos)))
          do (incf pos))
    (let* ((raw (subseq text start pos))
           (integerp (not (or (find #\. raw) (find #\e raw :test #'char-equal))))
           (value (handler-case
                      (if integerp
                          (parse-integer raw)
                          (coerce (read-from-string raw) 'double-float))
                    (error () (fail "invalid number")))))
      (values (make-jnum raw value integerp) pos))))

(defun parse-literal (text pos literal value)
  (let ((end (+ pos (length literal))))
    (if (and (<= end (length text)) (string= text literal :start1 pos :end1 end))
        (values value end)
        (fail "invalid literal"))))

(defun parse-json-array (text pos)
  (setf pos (skip-ws text (expect-char text pos #\[)))
  (let ((values '()))
    (when (and (< pos (length text)) (char= (char text pos) #\]))
      (return-from parse-json-array (values (make-jarray '()) (1+ pos))))
    (loop
      (multiple-value-bind (value next) (parse-json-value text pos)
        (push value values)
        (setf pos (skip-ws text next)))
      (cond
        ((and (< pos (length text)) (char= (char text pos) #\,))
         (setf pos (skip-ws text (1+ pos))))
        ((and (< pos (length text)) (char= (char text pos) #\]))
         (return (values (make-jarray (nreverse values)) (1+ pos))))
        (t (fail "expected comma or closing bracket"))))))

(defun parse-json-object (text pos)
  (setf pos (skip-ws text (expect-char text pos #\{)))
  (let ((pairs '()))
    (when (and (< pos (length text)) (char= (char text pos) #\}))
      (return-from parse-json-object (values (make-jobject '()) (1+ pos))))
    (loop
      (unless (and (< pos (length text)) (char= (char text pos) #\"))
        (fail "expected object key"))
      (let ((key nil))
        (multiple-value-bind (parsed-key next) (parse-json-string text pos)
          (setf key parsed-key
                pos (skip-ws text next)))
        (setf pos (skip-ws text (expect-char text pos #\:)))
        (multiple-value-bind (value next) (parse-json-value text pos)
          (push (cons key value) pairs)
          (setf pos (skip-ws text next))))
      (cond
        ((and (< pos (length text)) (char= (char text pos) #\,))
         (setf pos (skip-ws text (1+ pos))))
        ((and (< pos (length text)) (char= (char text pos) #\}))
         (return (values (make-jobject (nreverse pairs)) (1+ pos))))
        (t (fail "expected comma or closing brace"))))))

(defun parse-json-value (text pos)
  (setf pos (skip-ws text pos))
  (when (>= pos (length text)) (fail "unexpected end of JSON"))
  (case (char text pos)
    (#\n (parse-literal text pos "null" (make-jnull)))
    (#\t (parse-literal text pos "true" (make-jbool t)))
    (#\f (parse-literal text pos "false" (make-jbool nil)))
    (#\" (multiple-value-bind (s next) (parse-json-string text pos)
           (values (make-jstr s) next)))
    (#\[ (parse-json-array text pos))
    (#\{ (parse-json-object text pos))
    (otherwise (parse-json-number text pos))))

(defun parse-json (text)
  (multiple-value-bind (value pos) (parse-json-value text 0)
    (setf pos (skip-ws text pos))
    (unless (= pos (length text)) (fail "trailing data after JSON"))
    value))

(defun join-strings (strings separator)
  (with-output-to-string (out)
    (loop for item in strings
          for first = t then nil
          do (progn
               (unless first (write-string separator out))
               (write-string item out)))))

(defun stringify (value)
  (typecase value
    (jnull "")
    (jbool (if (jbool-value value) "true" "false"))
    (jstr (jstr-value value))
    (jnum (if (jnum-integerp value)
              (format nil "~D" (jnum-value value))
              (let ((*read-default-float-format* 'double-float))
                (string-downcase (format nil "~G" (jnum-value value))))))
    (jarray
     (format nil "[~A]"
             (join-strings (mapcar #'stringify (jarray-values value)) ", ")))
    (jobject
     (format nil "{~A}"
             (join-strings
              (mapcar (lambda (pair)
                        (format nil "~A=~A" (car pair) (stringify (cdr pair))))
                      (jobject-pairs value))
              ", ")))
    (t "")))

(defun object-lookup (key object)
  (if (jobject-p object)
      (let ((found (assoc key (jobject-pairs object) :test #'string=)))
        (if found (cdr found) (make-jnull)))
      (make-jnull)))

(defun truthy-p (value)
  (typecase value
    (jnull nil)
    (jbool (jbool-value value))
    (jnum (not (zerop (jnum-value value))))
    (t (not (string= (stringify value) "")))))

(defun looks-date-only-p (value)
  (and (= (length value) 10)
       (every #'digit-char-p (subseq value 0 4))
       (char= (char value 4) #\-)
       (every #'digit-char-p (subseq value 5 7))
       (char= (char value 7) #\-)
       (every #'digit-char-p (subseq value 8 10))))

(defun leap-year-p (year)
  (and (zerop (mod year 4))
       (or (not (zerop (mod year 100))) (zerop (mod year 400)))))

(defun days-in-month (year month)
  (case month
    ((1 3 5 7 8 10 12) 31)
    ((4 6 9 11) 30)
    (2 (if (leap-year-p year) 29 28))
    (otherwise 0)))

(defun parse-zone-hours (zone)
  (unless (and (= (length zone) 5)
               (find (char zone 0) "+-" :test #'char=)
               (every #'digit-char-p (subseq zone 1 5)))
    (return-from parse-zone-hours 0))
  (let* ((sign (if (char= (char zone 0) #\+) 1 -1))
         (hours (parse-integer zone :start 1 :end 3))
         (minutes (parse-integer zone :start 3 :end 5))
         (offset (+ hours (/ minutes 60))))
    (- (* sign offset))))

(defun date-to-universal-time (value &optional (zone-hours 0))
  (unless (looks-date-only-p value)
    (fail "parsing time \"~A\" as \"2006-01-02\": cannot parse \"~A\" as \"2006\"" value value))
  (let ((year (parse-integer value :start 0 :end 4))
        (month (parse-integer value :start 5 :end 7))
        (day (parse-integer value :start 8 :end 10)))
    (cond
      ((or (< year 1) (> year 9999)) (fail "year ~D is out of range" year))
      ((or (< month 1) (> month 12)) (fail "month must be in 1..12"))
      ((or (< day 1) (> day (days-in-month year month)))
       (fail "parsing time \"~A\": day out of range" value))
      (t (encode-universal-time 0 0 0 day month year zone-hours)))))

(defun trim-string (text)
  (string-trim '(#\Newline #\Return #\Space #\Tab) text))

(defun command-output (program args)
  (with-output-to-string (out)
    (uiop:run-program (cons program args) :output out :ignore-error-status t)))

(defun local-start-of-today ()
  (let* ((text (trim-string (command-output "date" '("+%Y-%m-%dT00:00:00%z"))))
         (date (if (>= (length text) 10) (subseq text 0 10) "1970-01-01"))
         (zone (if (>= (length text) 24) (subseq text 19 24) "+0000")))
    (date-to-universal-time date (parse-zone-hours zone))))

(defun fetch-url (url)
  (let ((status-file (make-pathname :name (format nil "semantic-drift-status-~D" (get-universal-time))
                                    :type "txt"
                                    :defaults (uiop:temporary-directory)))
        (body-file (make-pathname :name (format nil "semantic-drift-body-~D" (get-universal-time))
                                  :type "json"
                                  :defaults (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (uiop:run-program
            (list "curl" "-sS" "-X" "GET" "-w" "%{http_code}" "-o"
                  (namestring body-file) url)
            :output status-file
            :error-output *error-output*
            :ignore-error-status nil)
           (let ((status (parse-integer (trim-string (uiop:read-file-string status-file)))))
             (if (or (< status 200) (>= status 300))
                 (fail "bad status: ~D" status)
                 (uiop:read-file-string body-file))))
      (ignore-errors (delete-file status-file))
      (ignore-errors (delete-file body-file)))))

(defun compare-json-values (left right)
  (cond
    ((and (jnum-p left) (jnum-p right))
     (cond ((< (jnum-value left) (jnum-value right)) -1)
           ((> (jnum-value left) (jnum-value right)) 1)
           (t 0)))
    (t
     (let ((ls (stringify left))
           (rs (stringify right)))
       (cond ((string< ls rs) -1)
             ((string> ls rs) 1)
             (t 0))))))

(defun summary-less-p (left right)
  (cond
    ((/= (summary-completed left) (summary-completed right))
     (> (summary-completed left) (summary-completed right)))
    ((/= (summary-missed left) (summary-missed right))
     (> (summary-missed left) (summary-missed right)))
    (t (< (compare-json-values (summary-user-id left) (summary-user-id right)) 0))))

(defun pad-right (text width)
  (let ((text (princ-to-string text)))
    (if (>= (length text) width)
        text
        (concatenate 'string text (make-string (- width (length text)) :initial-element #\Space)))))

(defun summarize (today todos)
  (let ((items '()))
    (dolist (todo todos)
      (let* ((user-id (object-lookup "userId" todo))
             (key (stringify user-id))
             (entry (assoc key items :test #'string=))
             (summary (if entry (cdr entry) (make-summary user-id 0 0))))
        (if (truthy-p (object-lookup "completed" todo))
            (incf (summary-completed summary))
            (let ((due (date-to-universal-time
                        (stringify (object-lookup "dueDate" todo))
                        0)))
              (when (< due today)
                (incf (summary-missed summary)))))
        (if entry
            (setf (cdr entry) summary)
            (push (cons key summary) items))))
    (sort (mapcar #'cdr items) #'summary-less-p)))

(defun print-summary (summary)
  (format t "~A ~A ~D~%"
          (pad-right (stringify (summary-user-id summary)) 5)
          (pad-right (summary-completed summary) 10)
          (summary-missed summary)))

(defun run (args)
  (if (/= (length args) 1)
      (progn
        (format *error-output* "usage: ./run.sh <url>~%")
        2)
      (let* ((body (fetch-url (first args)))
             (value (parse-json body)))
        (unless (jarray-p value) (fail "expected JSON array"))
        (let ((rows (summarize (local-start-of-today) (jarray-values value))))
          (format t "USER  COMPLETED  MISSED~%")
          (dolist (row rows) (print-summary row))
          0))))

(defun main ()
  (handler-case
      (let ((code (run (cdr sb-ext:*posix-argv*))))
        (uiop:quit code))
    (program-error-message (err)
      (format *error-output* "~A~%" (error-message err))
      (uiop:quit 1))
    (error (err)
      (format *error-output* "~A~%" err)
      (uiop:quit 1))))

(main)
