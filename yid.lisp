(defpackage yid
  (:use #:cl #:lazy)
  (:export #:parser #:token #:eps #:con #:alt #:rep #:red
           #:*empty* #:*epsilon*
           #:parse #:parse-partial
           #:choice #:~ #:*+ #:==>
           #:recognizesp))

(in-package #:yid)

(defclass change-cell ()
  ((changedp :initform nil :accessor changedp)
   (seen :initform () :accessor seen)))

(defmethod or-with ((object change-cell) changed)
  (or (slot-value object 'changedp)
      (setf (slot-value object 'changedp) changed)))

(defclass parser ()
  ((parse-null :initform '())
   (emptyp :initform nil :initarg :emptyp)
   (nullablep :initform nil :initarg :nullablep)
   (initializedp :initform nil :accessor initializedp)
   (cache :initform (make-hash-table :test #'equal) :reader cache)))

(defclass token (parser)
  ((predicate :initarg :predicate)
   (parse-null :initform '())
   (emptyp :initform nil)
   (nullablep :initform nil)))

(defun token (predicate)
  (make-instance 'token :predicate predicate))

(defvar *empty* (make-instance 'parser :emptyp t :nullablep nil))

(defclass eps (parser)
  ((generator :initarg :generator :reader generator)
   (emptyp :initform nil)
   (nullablep :initform t)))

(defun eps (generator)
  (make-instance 'eps :generator generator))

(defvar *epsilon* (eps (cons-stream '() '())))

(defclass con (parser)
  ((left :initarg :left :reader left)
   (right :initarg :right :reader right)))

(defmacro con (left right)
  `(make-instance 'con :left (delay ,left) :right (delay ,right)))

(defclass alt (parser)
  ((choice1 :initarg :choice1 :reader choice1)
   (choice2 :initarg :choice2 :reader choice2)))

(defmacro alt (choice1 choice2)
  `(make-instance 'alt :choice1 (delay ,choice1) :choice2 (delay ,choice2)))

(defclass rep (parser)
  ((parser :initarg :parser)
   (parse-null :initform '(nil))
   (emptyp :initform nil)
   (nullablep :initform t)))

(defmacro rep (parser)
  `(make-instance 'rep :parser (delay ,parser)))

(defclass red (parser)
  ((parser :initarg :parser)
   (f :initarg :f)))

(defmacro red (parser f)
  `(make-instance 'red :parser (delay ,parser) :f ,f))

(defgeneric parse-null (parser)
  (:method ((parser lazy::lazy-form))
    (parse-null (force parser)))
  (:method (parser)
    (declare (ignore parser))
    '())
  (:method ((parser parser))
    (if (emptyp parser)
        '()
        (slot-value parser 'parse-null))))

(defgeneric nullablep (parser)
  (:method ((parser lazy::lazy-form))
    (nullablep (force parser)))
  (:method (parser)
    (declare (ignore parser))
    nil)
  (:method ((parser parser))
    (if (emptyp parser)
        nil
        (slot-value parser 'nullablep))))

(defgeneric emptyp (parser)
  (:method ((parser lazy::lazy-form))
    (emptyp (force parser)))
  (:method (parser)
    (declare (ignore parser))
    nil)
  (:method ((parser parser))
    (initialize-parser parser)
    (slot-value parser 'emptyp)))

;;; NOTE: These SETF functions behave differently from most. Rather than
;;;       returning the value they were passed, they return whether or not the
;;;       value changed.

(defun (setf parse-null) (value parser)
  (when (not (equal (slot-value parser 'parse-null) value))
    (setf (slot-value parser 'parse-null) value)
    t))

(defun (setf emptyp) (value parser)
  (when (not (eq (not (slot-value parser 'emptyp)) (not value)))
    (setf (slot-value parser 'emptyp) value)
    t))

(defun (setf nullablep) (value parser)
  (when (not (eq (not (slot-value parser 'nullablep)) (not value)))
    (setf (slot-value parser 'nullablep) value)
    t))

(defun initialize-parser (parser)
  (when (not (initializedp parser))
    (setf (initializedp parser) t)
    (loop
       for change = (make-instance 'change-cell)
       do (update-child-based-attributes parser change)
       while (changedp change))))

(defgeneric derive (parser value)
  (:method :around ((parser parser) value)
    (cond ((emptyp parser) *empty*)
          ((gethash value (cache parser)) (gethash value (cache parser)))
          (t (setf (gethash value (cache parser)) (call-next-method)))))
  (:method ((parser lazy::lazy-form) token)
    "Need this so the next method doesn't match on lazies."
    (derive (force parser) token))
  (:method (parser token)
    (if (equal parser token)
        (eps (cons-stream token '()))
        *empty*))
  (:method ((parser token) value)
    (if (funcall (slot-value parser 'predicate) value)
        (eps (cons-stream value '()))
        *empty*))
  (:method ((parser (eql *empty*)) value)
    (declare (ignore value))
    (error "Cannot derive the empty parser"))
  (:method ((parser eps) value)
    (declare (ignore value))
    *empty*)
  (:method ((parser con) value)
    (if (nullablep (left parser))
        (alt (con (derive (left parser) value)
                  (right parser))
             (con (eps (map-stream #'first (parse-partial (left parser) '())))
                  (derive (right parser) value)))
        (con (derive (left parser) value) (right parser))))
  (:method ((parser alt) value)
    (cond ((emptyp (choice1 parser)) (derive (choice2 parser) value))
          ((emptyp (choice2 parser)) (derive (choice1 parser) value))
          (t (alt (derive (choice1 parser) value)
                  (derive (choice2 parser) value)))))
  (:method ((parser rep) value)
    (con (derive (slot-value parser 'parser) value)
         parser))
  (:method ((parser red) value)
    (red (derive (slot-value parser 'parser) value)
         (slot-value parser 'f))))

(defgeneric parse (parser stream)
  (:method ((parser lazy::lazy-form) stream)
    (parse (force parser) stream))
  (:method (parser stream)
    (if (endp stream)
        (parse-null parser)
        (parse (derive parser (stream-car stream))
                    (stream-cdr stream))))
  (:method ((parser red) stream)
    (map-stream (lambda (a) (funcall (slot-value parser 'f) a))
                (parse (slot-value parser 'parser) stream))))

(defgeneric parse-partial (parser stream)
  (:method ((parser parser) stream)
    (if (endp stream)
        (mapcar (lambda (a) (list a '()))
                (parse-null parser))
        (combine-even (parse-partial (derive parser (stream-car stream))
                             (stream-cdr stream))
                      (map-stream (lambda (a) (list a stream))
                                  (parse parser '())))))
  (:method ((parser lazy::lazy-form) stream)
    "Need this so the next method doesn't match on lazies."
    (parse-partial (force parser) stream))
  (:method (parser stream)
    (if (equal parser (stream-car stream))
        (cons-stream (list (stream-car stream) (stream-cdr stream))
                     '())
        '()))
  (:method ((parser token) stream)
    (if (funcall (slot-value parser 'predicate) (stream-car stream))
        (cons-stream (list (stream-car stream) (stream-cdr stream))
                     '())
        '()))
  (:method ((parser (eql *empty*)) stream)
    (declare (ignore stream))
    '())
  (:method ((parser eps) stream)
    (map-stream (lambda (a) (list a stream)) (generator parser)))
  (:method ((parser red) stream)
    (map-stream (lambda (result)
                  (destructuring-bind (a &rest rest) result
                    (cons (funcall (slot-value parser 'f) a) rest)))
                (parse-partial (slot-value parser 'parser) stream))))

(defgeneric update-child-based-attributes (parser change)
  (:method ((parser lazy::lazy-form) change)
    (update-child-based-attributes (force parser) change))
  (:method (parser change)
    (declare (ignore parser change))
    (values))
  (:method ((parser eps) change)
    (or-with change
             (setf (parse-null parser) (for-each-stream (generator parser)))))
  (:method ((parser con) change)
    (when (not (find parser (seen change)))
      (push parser (seen change))
      (update-child-based-attributes (left parser) change)
      (update-child-based-attributes (right parser) change)
      (setf (initializedp parser) t))
    (or-with change
             (setf (parse-null parser)
                   (remove-duplicates
                    (mapcan (lambda (a)
                              (mapcar (lambda (b) (cons a b))
                                      (parse-null (right parser))))
                            (parse-null (left parser)))
                    :test #'equal)))
    (or-with change
             (setf (emptyp parser) (or (emptyp (left parser))
                                         (emptyp (right parser)))))
    (or-with change
             (setf (nullablep parser) (and (not (emptyp parser))
                                             (nullablep (left parser))
                                             (nullablep (right parser))))))
  (:method ((parser alt) change)
    (when (not (find parser (seen change)))
      (push parser (seen change))
      (update-child-based-attributes (choice1 parser) change)
      (update-child-based-attributes (choice2 parser) change)
      (setf (initializedp parser) t))
    (or-with change
             (setf (parse-null parser)
                   (union (parse-null (choice1 parser))
                          (parse-null (choice2 parser)))))
    (or-with change
             (setf (emptyp parser) (and (emptyp (choice1 parser))
                                          (emptyp (choice2 parser)))))
    (or-with change
             (setf (nullablep parser)
                   (and (not (emptyp parser))
                        (or (nullablep (choice1 parser))
                            (nullablep (choice2 parser)))))))  
  (:method ((parser rep) change)
    (when (not (find parser (seen change)))
      (push parser (seen change))
      (update-child-based-attributes (slot-value parser 'parser) change)
      (setf (initializedp parser) t)))
  (:method ((parser red) change)
    (when (not (find parser (seen change)))
      (push parser (seen change))
      (update-child-based-attributes (slot-value parser 'parser) change)
      (setf (initializedp parser) t))
    (or-with change
             (setf (parse-null parser)
                   (remove-duplicates
                    (mapcar (slot-value parser 'f)
                            (parse-null (slot-value parser 'parser)))
                    :test #'equal)))
    (or-with change
             (setf (emptyp parser) (emptyp (slot-value parser 'parser))))
    (or-with change
             (setf (nullablep parser)
                   (nullablep (slot-value parser 'parser))))))

(defmacro choice (&rest parsers)
  (case (length parsers)
    (0 `*empty*)
    (1 `,(car parsers))
    (otherwise `(alt ,(car parsers) (choice ,@(cdr parsers))))))

(defmacro ~ (&rest parsers)
  (case (length parsers)
    (0 `*epsilon*)
    (1 `,(car parsers))
    (otherwise `(con ,(car parsers) (~ ,@(cdr parsers))))))

(defmacro *+ (parser)
  `(rep ,parser))

(defmacro ==> (parser function)
  `(red ,parser ,function))

(defun combine-even (s1 s2)
  (cond (s1 (cons-stream (stream-car s1) (combine-odd (stream-cdr s1) s2)))
        (s2 (cons-stream (stream-car s2) (combine-odd s1 (stream-cdr s2))))
        (t '())))

(defun combine-odd (s1 s2)
  (cond (s2 (cons-stream (stream-car s2) (combine-even s1 (stream-cdr s2))))
        (s1 (cons-stream (stream-car s1) (combine-even (stream-cdr s1) s2)))
        (t '())))

(defgeneric recognizesp (parser stream)
  (:method (parser stream)
    (if (endp stream)
        (nullablep parser)
        (recognizesp (derive parser (stream-car stream)) (stream-cdr stream))))
  (:method ((parser lazy::lazy-form) stream)
    (recognizesp (force parser) stream)))
