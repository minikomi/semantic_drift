(require :asdf)

(defstruct (jv (:constructor make-jv (type value)))
  type
  value)

(defparameter *undefined* (make-jv :undefined nil))

(defstruct parser
  text
  (pos 0))

(define-condition app-error (error)
  ((message :initarg :message :reader app-error-message))
  (:report (lambda (c s) (princ (app-error-message c) s))))

(defun fail-msg (message)
  (error 'app-error :message message))

(defun whitespace-char-p (c)
  (or (char= c #\Space) (char= c #\Newline) (char= c #\Return) (char= c #\Tab)))

(defun skip-ws (p)
  (loop while (and (< (parser-pos p) (length (parser-text p)))
                   (whitespace-char-p (char (parser-text p) (parser-pos p))))
        do (incf (parser-pos p)))
  p)

(defun peek-char-p (p)
  (if (>= (parser-pos p) (length (parser-text p)))
      (fail-msg "unexpected end of input")
      (char (parser-text p) (parser-pos p))))

(defun consume (c p)
  (if (and (< (parser-pos p) (length (parser-text p)))
           (char= (char (parser-text p) (parser-pos p)) c))
      (progn (incf (parser-pos p)) t)
      nil))

(defun expect (c p)
  (unless (consume c p)
    (fail-msg (format nil "expected '~C'" c)))
  p)

(defun literal (word p)
  (let* ((s (parser-text p))
         (pos (parser-pos p))
         (end (+ pos (length word))))
    (if (and (<= end (length s)) (string= word s :start2 pos :end2 end))
        (progn (setf (parser-pos p) end) p)
        (fail-msg "unexpected token"))))

(defun hex-value (c)
  (cond
    ((and (char>= c #\0) (char<= c #\9)) (- (char-code c) (char-code #\0)))
    ((and (char>= c #\a) (char<= c #\f)) (+ 10 (- (char-code c) (char-code #\a))))
    ((and (char>= c #\A) (char<= c #\F)) (+ 10 (- (char-code c) (char-code #\A))))
    (t nil)))

(defun parse-hex4 (p)
  (when (> (+ (parser-pos p) 4) (length (parser-text p)))
    (fail-msg "invalid unicode escape"))
  (let ((acc 0))
    (dotimes (_ 4)
      (let ((hv (hex-value (char (parser-text p) (parser-pos p)))))
        (unless hv
          (fail-msg "invalid unicode escape"))
        (setf acc (+ (ash acc 4) hv))
        (incf (parser-pos p))))
    acc))

(defun parse-json-string (p)
  (expect #\" p)
  (with-output-to-string (out)
    (loop
      (when (>= (parser-pos p) (length (parser-text p)))
        (fail-msg "unterminated string"))
      (let ((c (char (parser-text p) (parser-pos p))))
        (incf (parser-pos p))
        (cond
          ((char= c #\") (return))
          ((< (char-code c) #x20) (fail-msg "control character in string"))
          ((char= c #\\)
           (when (>= (parser-pos p) (length (parser-text p)))
             (fail-msg "invalid escape"))
           (let ((esc (char (parser-text p) (parser-pos p))))
             (incf (parser-pos p))
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
                (let ((cp (parse-hex4 p)))
                  (when (and (>= cp #xD800) (<= cp #xDBFF))
                    (when (or (> (+ (parser-pos p) 6) (length (parser-text p)))
                              (char/= (char (parser-text p) (parser-pos p)) #\\)
                              (char/= (char (parser-text p) (1+ (parser-pos p))) #\u))
                      (fail-msg "invalid unicode surrogate"))
                    (incf (parser-pos p) 2)
                    (let ((low (parse-hex4 p)))
                      (when (or (< low #xDC00) (> low #xDFFF))
                        (fail-msg "invalid unicode surrogate"))
                      (setf cp (+ #x10000 (ash (- cp #xD800) 10) (- low #xDC00)))))
                  (write-char (code-char cp) out)))
               (otherwise (fail-msg "invalid escape")))))
          (t (write-char c out)))))))

(defun digit-char-json-p (c)
  (and (char>= c #\0) (char<= c #\9)))

(defun consume-digits (p)
  (loop while (and (< (parser-pos p) (length (parser-text p)))
                   (digit-char-json-p (char (parser-text p) (parser-pos p))))
        do (incf (parser-pos p)))
  p)

(defun parse-number (p)
  (let* ((s (parser-text p))
         (begin (parser-pos p)))
    (when (and (< (parser-pos p) (length s))
               (member (char s (parser-pos p)) '(#\+ #\-) :test #'char=))
      (incf (parser-pos p)))
    (consume-digits p)
    (when (and (< (parser-pos p) (length s)) (char= (char s (parser-pos p)) #\.))
      (incf (parser-pos p))
      (consume-digits p))
    (when (and (< (parser-pos p) (length s))
               (member (char s (parser-pos p)) '(#\e #\E) :test #'char=))
      (let ((save (parser-pos p)))
        (incf (parser-pos p))
        (when (and (< (parser-pos p) (length s))
                   (member (char s (parser-pos p)) '(#\+ #\-) :test #'char=))
          (incf (parser-pos p)))
        (let ((exp-begin (parser-pos p)))
          (consume-digits p)
          (when (= exp-begin (parser-pos p))
            (setf (parser-pos p) save)))))
    (let ((end (parser-pos p)))
      (when (or (= begin end)
                (and (= end (1+ begin))
                     (member (char s begin) '(#\+ #\-) :test #'char=)))
        (fail-msg "unexpected token"))
      (let ((txt (subseq s begin end)))
        (handler-case
            (multiple-value-bind (n used) (read-from-string txt)
              (if (and (= used (length txt)) (numberp n))
                  (make-jv :number (coerce n 'double-float))
                  (fail-msg "unexpected token")))
          (error () (fail-msg "unexpected token")))))))

(defun add-or-replace (key value fields)
  (cond
    ((null fields) (list (cons key value)))
    ((string= key (caar fields)) (cons (cons key value) (cdr fields)))
    (t (cons (car fields) (add-or-replace key value (cdr fields))))))

(defun parse-array (p)
  (expect #\[ p)
  (skip-ws p)
  (if (consume #\] p)
      (make-jv :array nil)
      (let ((acc nil))
        (loop
          (push (parse-value p) acc)
          (skip-ws p)
          (when (consume #\] p)
            (return (make-jv :array (nreverse acc))))
          (expect #\, p)))))

(defun parse-object (p)
  (expect #\{ p)
  (skip-ws p)
  (if (consume #\} p)
      (make-jv :object nil)
      (let ((fields nil))
        (loop
          (let ((key (parse-json-string (skip-ws p))))
            (expect #\: (skip-ws p))
            (let ((val (parse-value p)))
              (setf fields (add-or-replace key val fields))))
          (skip-ws p)
          (when (consume #\} p)
            (return (make-jv :object fields)))
          (expect #\, p)))))

(defun parse-value (p)
  (skip-ws p)
  (case (peek-char-p p)
    (#\n (literal "null" p) (make-jv :null nil))
    (#\t (literal "true" p) (make-jv :bool t))
    (#\f (literal "false" p) (make-jv :bool nil))
    (#\" (make-jv :string (parse-json-string p)))
    (#\[ (parse-array p))
    (#\{ (parse-object p))
    (otherwise (parse-number p))))

(defun parse-json (s)
  (let ((p (make-parser :text s)))
    (let ((v (parse-value (skip-ws p))))
      (skip-ws p)
      (if (/= (parser-pos p) (length s))
          (fail-msg (format nil "unexpected token at '~C'" (char s (parser-pos p))))
          v))))

(defun join-with (sep xs)
  (if xs
      (reduce (lambda (a b) (concatenate 'string a sep b)) xs)
      ""))

(defun json-string-escape (s)
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for c across s do
      (case c
        (#\" (write-string "\\\"" out))
        (#\\ (write-string "\\\\" out))
        (#.(code-char 8) (write-string "\\b" out))
        (#.(code-char 12) (write-string "\\f" out))
        (#\Newline (write-string "\\n" out))
        (#\Return (write-string "\\r" out))
        (#\Tab (write-string "\\t" out))
        (otherwise
         (if (< (char-code c) #x20)
             (format out "\\u~4,'0x" (char-code c))
             (write-char c out)))))
    (write-char #\" out)))

(defparameter +min-long-double+ -9223372036854775808.0d0)
(defparameter +max-long-double+ 9223372036854775808.0d0)

(defun number-is-integer (n)
  (and (not (sb-ext:float-nan-p n))
       (not (sb-ext:float-infinity-p n))
       (= (floor n) n)
       (>= n +min-long-double+)
       (<= n +max-long-double+)))

(defun number-to-string (n)
  (cond
    ((and (number-is-integer n) (>= n +max-long-double+)) "9223372036854775807")
    ((and (number-is-integer n) (<= n +min-long-double+)) "-9223372036854775808")
    ((number-is-integer n) (format nil "~D" (truncate n)))
    (t (let ((txt (format nil "~,15G" n)))
         (string-downcase (string-trim '(#\Space) txt))))))

(defun py-repr (v)
  (case (jv-type v)
    (:undefined "undefined")
    (:null "None")
    (:bool (if (jv-value v) "True" "False"))
    (:number (number-to-string (jv-value v)))
    (:string (json-string-escape (jv-value v)))
    (:array (format nil "[~A]" (join-with ", " (mapcar #'py-repr (jv-value v)))))
    (:object (format nil "{~A}"
                     (join-with ", "
                                (mapcar (lambda (f)
                                          (format nil "~A: ~A"
                                                  (py-repr (make-jv :string (car f)))
                                                  (py-repr (cdr f))))
                                        (jv-value v)))))))

(defun js-string (v)
  (case (jv-type v)
    (:undefined "undefined")
    (:null "null")
    (:bool (if (jv-value v) "true" "false"))
    (:string (jv-value v))
    (:number (number-to-string (jv-value v)))
    ((:array :object) (py-repr v))))

(defun py-str (v)
  (case (jv-type v)
    (:null "None")
    (:bool (if (jv-value v) "True" "False"))
    ((:array :object) (py-repr v))
    (otherwise (js-string v))))

(defun js-json-stringify (v)
  (case (jv-type v)
    (:undefined "undefined")
    (:null "null")
    (:bool (if (jv-value v) "true" "false"))
    (:number (number-to-string (jv-value v)))
    (:string (json-string-escape (jv-value v)))
    (:array (format nil "[~A]" (join-with "," (mapcar #'js-json-stringify (jv-value v)))))
    (:object (format nil "{~A}"
                     (join-with ","
                                (mapcar (lambda (f)
                                          (format nil "~A:~A"
                                                  (json-string-escape (car f))
                                                  (js-json-stringify (cdr f))))
                                        (jv-value v)))))))

(defun python-truthy (v)
  (case (jv-type v)
    (:undefined t)
    (:null nil)
    (:bool (jv-value v))
    (:number (/= (jv-value v) 0.0d0))
    (:string (> (length (jv-value v)) 0))
    (:array (not (null (jv-value v))))
    (:object (not (null (jv-value v))))))

(defun object-get (v key)
  (if (eq (jv-type v) :object)
      (let ((found (assoc key (jv-value v) :test #'string=)))
        (if found (cdr found) *undefined*))
      *undefined*))

(defun leap-year-p (year)
  (and (zerop (mod year 4))
       (or (not (zerop (mod year 100))) (zerop (mod year 400)))))

(defun days-in-month (year month)
  (case month
    ((1 3 5 7 8 10 12) 31)
    ((4 6 9 11) 30)
    (2 (if (leap-year-p year) 29 28))
    (otherwise 0)))

(defun parse-date-only (v)
  (let* ((txt (js-string v))
         (shape (and (= (length txt) 10)
                     (every #'digit-char-json-p (subseq txt 0 4))
                     (char= (char txt 4) #\-)
                     (every #'digit-char-json-p (subseq txt 5 7))
                     (char= (char txt 7) #\-)
                     (every #'digit-char-json-p (subseq txt 8)))))
    (unless shape
      (fail-msg (format nil "parsing time ~A as \"2006-01-02\": cannot parse date"
                        (js-json-stringify v))))
    (let ((year (parse-integer txt :start 0 :end 4))
          (month (parse-integer txt :start 5 :end 7))
          (day (parse-integer txt :start 8)))
      (when (or (and (>= year 0) (<= year 99))
                (< month 1) (> month 12)
                (< day 1) (> day (days-in-month year month)))
        (fail-msg (format nil "parsing time ~A: day out of range" (js-json-stringify v))))
      (encode-universal-time 0 0 0 day month year 0))))

(defun canonical-key (v)
  (js-json-stringify v))

(defstruct summary
  user-id
  (completed 0)
  (missed 0))

(defun adjust-summary (user-id fn summaries)
  (cond
    ((null summaries) (list (funcall fn (make-summary :user-id user-id))))
    ((string= (canonical-key (summary-user-id (car summaries))) (canonical-key user-id))
     (cons (funcall fn (car summaries)) (cdr summaries)))
    (t (cons (car summaries) (adjust-summary user-id fn (cdr summaries))))))

(defun utf16-units (s)
  (loop for c across s append
    (let ((code (char-code c)))
      (if (<= code #xFFFF)
          (list code)
          (let ((x (- code #x10000)))
            (list (+ #xD800 (floor x #x400)) (+ #xDC00 (mod x #x400))))))))

(defun compare-java-string (a b)
  (let ((ua (utf16-units a))
        (ub (utf16-units b)))
    (cond ((equal ua ub) 0)
          ((loop for x in ua for y in ub
                 when (< x y) do (return t)
                 when (> x y) do (return nil)
                 finally (return (< (length ua) (length ub)))) -1)
          (t 1))))

(defun py-key (v)
  (case (jv-type v)
    (:null (list 0 0.0d0 ""))
    (:bool (list 1 (if (jv-value v) 1.0d0 0.0d0) ""))
    (:number (list 1 (jv-value v) ""))
    (:string (list 2 0.0d0 (jv-value v)))
    (otherwise (list 3 0.0d0 (js-string v)))))

(defun compare-py-key< (a b)
  (destructuring-bind (ga na ta) (py-key a)
    (destructuring-bind (gb nb tb) (py-key b)
      (cond
        ((< ga gb) t)
        ((> ga gb) nil)
        ((and (= ga 1) (/= na nb)) (< na nb))
        (t (< (compare-java-string ta tb) 0))))))

(defun java-length (s)
  (loop for c across s sum (if (> (char-code c) #xFFFF) 2 1)))

(defun ljust (s width)
  (if (>= (java-length s) width)
      s
      (concatenate 'string s (make-string (- width (java-length s)) :initial-element #\Space))))

(defun split-http-response (s)
  (let* ((sep (or (search (format nil "~C~C~C~C" #\Return #\Newline #\Return #\Newline) s)
                  (search (format nil "~C~C" #\Newline #\Newline) s)))
         (sep-len (if (and sep
                           (<= (+ sep 4) (length s))
                           (string= (format nil "~C~C~C~C" #\Return #\Newline #\Return #\Newline)
                                    s :start2 sep :end2 (+ sep 4)))
                      4
                      2))
         (header (if sep (subseq s 0 sep) s))
         (body (if sep (subseq s (+ sep sep-len)) ""))
         (line-end (or (position #\Return header) (position #\Newline header) (length header)))
         (status-line (subseq header 0 line-end))
         (words (uiop:split-string status-line :separator '(#\Space #\Tab)))
         (clean-words (remove "" words :test #'string=))
         (status (and (>= (length clean-words) 2)
                      (member (first clean-words) '("HTTP/1.0" "HTTP/1.1" "HTTP/2" "HTTP/3")
                              :test #'string=)
                      (every #'digit-char-json-p (second clean-words))
                      (parse-integer (second clean-words))))
         (reason (if (>= (length clean-words) 3)
                     (join-with " " (cddr clean-words))
                     "")))
    (values status reason body)))

(defun trim-trailing-newline (s)
  (string-right-trim '(#\Newline) s))

(defun fetch-json (url)
  (multiple-value-bind (out err code)
      (uiop:run-program (list "curl" "--silent" "--show-error" "--include"
                              "--max-time" "10" "--connect-timeout" "10" url)
                        :output :string :error-output :string :ignore-error-status t)
    (if (zerop code)
        (multiple-value-bind (status reason body) (split-http-response out)
          (cond
            ((and status (>= status 200) (< status 300)) (parse-json body))
            (status (fail-msg (concatenate 'string
                                           "bad status: " (write-to-string status)
                                           (if (string= reason "") "" (concatenate 'string " " reason)))))
            (t (fail-msg "bad status: 000"))))
        (fail-msg (trim-trailing-newline err)))))

(defun today-universal-day ()
  (multiple-value-bind (_sec _min _hour day month year)
      (get-decoded-time)
    (declare (ignore _sec _min _hour))
    (encode-universal-time 0 0 0 day month year 0)))

(defun process-todos (today todos)
  (let ((summaries nil))
    (when (eq (jv-type todos) :array)
      (dolist (todo (jv-value todos))
        (let ((user-id (object-get todo "userId"))
              (completed (object-get todo "completed")))
          (if (python-truthy completed)
              (setf summaries
                    (adjust-summary user-id
                                    (lambda (s) (incf (summary-completed s)) s)
                                    summaries))
              (let ((due (parse-date-only (object-get todo "dueDate"))))
                (if (< due today)
                    (setf summaries
                          (adjust-summary user-id
                                          (lambda (s) (incf (summary-missed s)) s)
                                          summaries))
                    (setf summaries (adjust-summary user-id #'identity summaries))))))))
    (setf summaries
          (sort summaries
                (lambda (a b)
                  (cond
                    ((/= (summary-completed a) (summary-completed b))
                     (> (summary-completed a) (summary-completed b)))
                    ((/= (summary-missed a) (summary-missed b))
                     (> (summary-missed a) (summary-missed b)))
                    (t (compare-py-key< (summary-user-id a) (summary-user-id b)))))))
    (with-output-to-string (out)
      (write-string "USER  COMPLETED  MISSED
" out)
      (dolist (s summaries)
        (format out "~A ~A ~D~%"
                (ljust (py-str (summary-user-id s)) 5)
                (ljust (write-to-string (summary-completed s)) 10)
                (summary-missed s))))))

(defun main ()
  (let ((args (uiop:command-line-arguments)))
    (handler-case
        (if (= (length args) 1)
            (write-string (process-todos (today-universal-day) (fetch-json (first args))))
            (progn
              (format *error-output* "usage: TodoReport <todos-url>~%")
              (uiop:quit 1)))
      (error (e)
        (format *error-output* "~A~%" e)
        (uiop:quit 1)))))

(main)
