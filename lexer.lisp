;;;; Pattern Matching and Lexing package for LispWorks
;;;;
;;;; Copyright (c) 2012 by Jeffrey Massung
;;;;
;;;; This file is provided to you under the Apache License,
;;;; Version 2.0 (the "License"); you may not use this file
;;;; except in compliance with the License.  You may obtain
;;;; a copy of the License at
;;;;
;;;;    http://www.apache.org/licenses/LICENSE-2.0
;;;;
;;;; Unless required by applicable law or agreed to in writing,
;;;; software distributed under the License is distributed on an
;;;; "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
;;;; KIND, either express or implied.  See the License for the
;;;; specific language governing permissions and limitations
;;;; under the License.
;;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "parsergen"))

(defpackage :lexer
  (:use :cl :lw :parsergen)
  (:nicknames :lex)
  (:export
   #:re
   #:re-match

   ;; macros
   #:with-re-match
   #:deflexer

   ;; functions
   #:slurp
   #:push-lexer
   #:pop-lexer
   #:swap-lexer
   #:tokenize
   #:parse

   ;; pattern functions
   #:compile-re
   #:match-re
   #:find-re
   #:split-re
   #:replace-re

   ;; re accessors
   #:re-pattern
   #:re-case-fold-p
   #:re-multi-line-p

   ;; match readers
   #:match-string
   #:match-captures
   #:match-pos-start
   #:match-pos-end

   ;; lexbuf readers
   #:lex-lexeme
   #:lex-pos
   #:lex-line
   #:lex-source
   #:lex-buf

   ;; token readers
   #:token-line
   #:token-source
   #:token-class
   #:token-value
   #:token-lexeme))

(in-package :lexer)

(defclass re ()
  ((pattern    :initarg :pattern    :reader re-pattern)
   (case-fold  :initarg :case-fold  :reader re-case-fold-p)
   (multi-line :initarg :multi-line :reader re-multi-line-p)
   (expression :initarg :expression :reader re-expression))
  (:documentation "Regular expression."))

(defclass re-match ()
  ((match     :initarg :match     :reader match-string)
   (captures  :initarg :captures  :reader match-captures)
   (start-pos :initarg :start-pos :reader match-pos-start)
   (end-pos   :initarg :end-pos   :reader match-pos-end))
  (:documentation "Matched token."))

(defclass lex-state ()
  ((stream   :initarg :stream   :reader lex-stream)
   (start    :initarg :start    :reader lex-start)
   (captures :initarg :captures :reader lex-captures)
   (newline  :initarg :newline  :reader lex-newline))
  (:documentation "Token pattern matching state."))

(defclass lexbuf ()
  ((string :initarg :string :reader lex-string)
   (source :initarg :source :reader lex-source)
   (pos    :initarg :pos    :reader lex-pos    :initform 0)
   (line   :initarg :line   :reader lex-line   :initform 1)
   (lexeme :initarg :lexeme :reader lex-lexeme :initform nil))
  (:documentation "The input source for a DEFLEXER."))

(defclass token ()
  ((line   :initarg :line   :reader token-line)
   (source :initarg :source :reader token-source)
   (class  :initarg :class  :reader token-class)
   (value  :initarg :value  :reader token-value)
   (lexeme :initarg :lexeme :reader token-lexeme))
  (:documentation "A parsed token from a lexbuf."))

(define-condition lex-error (error)
  ((reason :initarg :reason :reader lex-error-reason)
   (line   :initarg :line   :reader lex-error-line)
   (source :initarg :source :reader lex-error-source)
   (lexeme :initarg :lexeme :reader lex-error-lexeme))
  (:documentation "Signaled when an error occurs during tokenizing or parsing.")
  (:report (lambda (c s)
             (with-slots (reason line source lexeme)
                 c
               (format s "~a on line ~a~@[ of ~s~]~@[ near ~s~]" reason line source lexeme)))))

(define-condition re-pattern-error (condition)
  ()
  (:documentation "Signaled when a regular expression parse fails."))

(defmethod print-object ((re re) s)
  "Output a regular expression to a stream."
  (print-unreadable-object (re s :type t)
    (format s "~s" (re-pattern re))))

(defmethod print-object ((match re-match) s)
  "Output a regular expression match to a stream."
  (print-unreadable-object (match s :type t)
    (format s "~s" (match-string match))))

(defmethod print-object ((token token) s)
  "Output a token to a stream."
  (print-unreadable-object (token s :type t)
    (with-slots (class value)
        token
      (format s "~a~@[ ~s~]" class value))))

(defmethod make-load-form ((re re) &optional env)
  "Tell the system how to save and load a regular expression to a FASL."
  (with-slots (pattern case-fold multi-line)
      re
    `(compile-re ,pattern :case-fold ,case-fold :multi-line ,multi-line)))

(defvar *lexbuf*)
(defvar *lexer*)

(defvar *case-fold* nil "Case-insentitive comparison.")
(defvar *multi-line* nil "Dot and EOL also match newlines.")

(defconstant +lowercase-letter+ "abcdefghijklmnopqrstuvwxyz")
(defconstant +uppercase-letter+ "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
(defconstant +digit+ "0123456789")
(defconstant +hex-digit+ "0123456789abcdefABCDEF")
(defconstant +punctuation+ "`~!@#$%^&*()-+=[]{}\|;:',./<>?\"")
(defconstant +letter+ (concatenate 'string +lowercase-letter+ +uppercase-letter+))
(defconstant +alpha-numeric+ (concatenate 'string +letter+ +digit+))
(defconstant +spaces+ (format nil "~c~c" #\space #\tab))
(defconstant +newlines+ (format nil "~c~c~c" #\newline #\return #\linefeed))

(defun range-chars (from to)
  "Return an inclusive list of characters in ascii order."
  (loop :for c :from (char-code from) :to (char-code to) :collect (code-char c)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (flet ((dispatch-re (s c n)
           (declare (ignorable c n))
           (let ((re (with-output-to-string (re)
                       (loop :for c := (read-char s t nil t) :do
                         (case c
                           (#\/ (return))
                           (#\\ (let ((c (read-char s t nil t)))
                                  (princ c re)))
                           (otherwise
                            (princ c re)))))))
             (compile-re re))))
    (set-dispatch-macro-character #\# #\/ #'dispatch-re)))

(defmacro with-re-match ((v match) &body body)
  "Intern match symbols to execute a body."
  (let (($$ (intern "$$" *package*))
        ($1 (intern "$1" *package*))
        ($2 (intern "$2" *package*))
        ($3 (intern "$3" *package*))
        ($4 (intern "$4" *package*))
        ($5 (intern "$5" *package*))
        ($6 (intern "$6" *package*))
        ($7 (intern "$7" *package*))
        ($8 (intern "$8" *package*))
        ($9 (intern "$9" *package*))
        ($_ (intern "$_" *package*)))
    `(let ((,v ,match))
       (destructuring-bind (&optional ,$$ ,$1 ,$2 ,$3 ,$4 ,$5 ,$6 ,$7 ,$8 ,$9 &rest ,$_)
           (when ,v
             (cons (match-string ,v) (match-captures ,v)))
         (declare (ignorable ,$$ ,$1 ,$2 ,$3 ,$4 ,$5 ,$6 ,$7 ,$8 ,$9 ,$_))
         (progn ,@body)))))

(defmacro deflexer (lexer (&rest re-options) &body patterns)
  "Create a tokenizing function."
  (let ((string (gensym "string"))
        (source (gensym "source"))
        (pos (gensym "pos"))
        (line (gensym "line"))
        (lexeme (gensym "lexeme"))
        (next-token (gensym "next-token"))
        (match (gensym "match"))
        (class (gensym "class"))
        (value (gensym "value")))
    `(defun ,lexer ()
       (with-slots ((,string string) (,source source) (,pos pos) (,line line) (,lexeme lexeme))
           *lexbuf*
         (prog
             ()
          ,next-token
          ,@(loop :for pattern :in patterns :collect
                  (destructuring-bind (p &body body)
                      pattern
                    (let ((re (apply #'compile-re (cons p re-options))))
                      `(with-re-match (,match (match-re ,re ,string :start ,pos))
                         (when ,match
                           (incf ,line (count #\newline (match-string ,match)))
                           (setf ,pos (match-pos-end ,match))
                           (setf ,lexeme (subseq ,string (match-pos-start ,match) ,pos))
                           (multiple-value-bind (,class ,value)
                               (progn ,@body)
                             (if (eq ,class :next-token)
                                 (go ,next-token)
                               (return (when ,class
                                         (make-instance 'token
                                                        :class ,class
                                                        :value ,value
                                                        :line ,line
                                                        :source ,source
                                                        :lexeme ,lexeme))))))))))
          (unless (>= ,pos (length ,string))
            (error (make-instance 'lex-error
                                  :reason "Lexing error"
                                  :line ,line
                                  :source ,source
                                  :lexeme (string (char ,string ,pos))))))))))

(defun slurp (pathname)
  "Read a file into a string sequence."
  (with-open-file (stream pathname)
    (let ((seq (make-array (file-length stream) :element-type 'character :fill-pointer t)))
      (prog1
          seq
        (setf (fill-pointer seq) (read-sequence seq stream))))))

(defun push-lexer (lexer class &optional value)
  "Push a new lexer and return a token."
  (multiple-value-prog1
      (values class value)
    (push lexer *lexer*)))

(defun pop-lexer (class &optional value)
  "Pop the top lexer and return a token."
  (multiple-value-prog1
      (values class value)
    (pop *lexer*)))

(defun swap-lexer (lexer class &optional value)
  "Set the current lexer and return a token."
  (multiple-value-prog1
      (values class value)
    (rplaca *lexer* lexer)))

(defun tokenize (lexer string &optional source)
  "Create a function that can be used in a parsergen."
  (let ((*lexbuf* (make-instance 'lexbuf :string string :source source)))
    (loop :with *lexer* := (list lexer)
          :while *lexer*
          :nconc (loop :for token := (funcall (first *lexer*))
                       :while token
                       :collect token)
          :do (pop *lexer*))))

(defun parse (parser tokens)
  "Set the lexer and parse the source with it."
  (let (token)
    (flet ((next-token ()
             (when (setf token (pop tokens))
               (values (token-class token)
                       (token-value token)))))
      (handler-case
          (funcall parser #'next-token)
        (condition (c)
          (if (null token)
              (error c)
            (error (make-instance 'lex-error
                                  :reason c
                                  :line (token-line token)
                                  :source (token-source token)
                                  :lexeme (token-lexeme token)))))))))

(defparser re-parser
  ((start compound)
   $1)

  ;; multiple expressions bound together
  ((compound capture compound)
   (bind $1 $2))
  ((compound capture)
   $1)

  ;; captured expression
  ((capture :capture compound :end-capture)
   (capture $2))
  ((capture simple)
   $1)

  ;; optional, repeating expressions
  ((simple expr :maybe)
   (maybe $1))
  ((simple expr :many)
   (many $1))
  ((simple expr :many1)
   (many1 $1))
  ((simple expr :to)
   (many $1))
  ((simple expr)
   $1)

  ;; bounded expression
  ((expr :between) 
   (between (ch (car $1) :case-fold *case-fold*)
            (ch (cdr $1) :case-fold *case-fold*)))

  ;; single character
  ((expr :char)
   (ch $1 :case-fold *case-fold*))

  ;; any character and end of line/input
  ((expr :any)
   (any-char :match-newline-p (not *multi-line*)))
  ((expr :eol)
   (eol :match-newline-p *multi-line*))
  ((expr :none)
   (newline :match-newline-p *multi-line*))

  ;; sets of characters
  ((expr :one-of)
   (one-of $1))
  ((expr :none-of)
   (none-of $1))
  ((expr :set set)
   $2)

  ;; unknown pattern
  ((expr :error)
   (error 're-pattern-error))

  ;; inclusive and exclusive sets
  ((set :none chars)
   (none-of $2 :case-fold *case-fold*))
  ((set chars)
   (one-of $1 :case-fold *case-fold*))

  ;; character set (just a list of characters)
  ((chars :one-of chars)
   (append (coerce $1 'list) $2))
  ((chars :char :to :char chars)
   (append (range-chars $1 $3) $4))
  ((chars :eol chars)
   (cons #\$ $2))
  ((chars :any chars)
   (cons #\. $2))
  ((chars :capture chars)
   (cons #\( $2))
  ((chars :end-capture chars)
   (cons #\) $2))
  ((chars :maybe chars)
   (cons #\? $2))
  ((chars :many chars)
   (cons #\* $2))
  ((chars :many1 chars)
   (cons #\+ $2))
  ((chars :char chars)
   (cons $1 $2))
  ((chars :to :end-set)
   (list #\-))
  ((chars :end-set)
   nil))

(defun compile-re (pattern &key case-fold multi-line)
  "Create a regular expression pattern match."
  (let ((*case-fold* case-fold)
        (*multi-line* multi-line))
    (with-input-from-string (s pattern)
      (flet ((next-token ()
               (let ((c (read-char s nil nil)))
                 (when c
                   (case c
                     (#\%
                      (let ((c (read-char s)))
                        (case c
                          (#\b (let ((b1 (read-char s))
                                     (b2 (read-char s)))
                                 (values :between (cons b1 b2))))
                          (#\s (values :one-of +spaces+))
                          (#\S (values :none-of +spaces+))
                          (#\n (values :one-of +newlines+))
                          (#\N (values :none-of +newlines+))
                          (#\a (values :one-of +letter+))
                          (#\A (values :none-of +letter+))
                          (#\l (values :one-of +lowercase-letter+))
                          (#\L (values :none-of +lowercase-letter+))
                          (#\u (values :one-of +uppercase-letter+))
                          (#\U (values :none-of +uppercase-letter+))
                          (#\p (values :one-of +punctuation+))
                          (#\P (values :none-of +punctuation+))
                          (#\w (values :one-of +alpha-numeric+))
                          (#\W (values :none-of +alpha-numeric+))
                          (#\d (values :one-of +digit+))
                          (#\D (values :none-of +digit+))
                          (#\x (values :one-of +hex-digit+))
                          (#\X (values :none-of +hex-digit+))
                          (#\z (values :char #\null))
                          (otherwise
                           (values :char c)))))
                     (#\$ :eol)
                     (#\. :any)
                     (#\^ :none)
                     (#\( :capture)
                     (#\) :end-capture)
                     (#\[ :set)
                     (#\] :end-set)
                     (#\? :maybe)
                     (#\* :many)
                     (#\+ :many1)
                     (#\- :to)
                     (otherwise
                      (values :char c)))))))
        (let ((expr (re-parser #'next-token)))
          (when expr
            (make-instance 're 
                           :pattern pattern 
                           :case-fold case-fold
                           :multi-line multi-line
                           :expression expr)))))))

(defun reduce-captures (s captures)
  "Reverse capture order and fetch their match."
  (flet ((capture (all capture)
           (if capture
               (with-slots (start-pos end-pos captures)
                   capture
                 (nconc (cons (subseq s start-pos end-pos) (reduce-captures s captures)) all))
             (push nil all))))
    (reduce #'capture captures :initial-value nil)))

(defun match-re (re s &key (start 0) (end (length s)) exact)
  "Check to see if a regexp pattern matches a string."
  (with-input-from-string (stream s :start start :end end)
    (let ((st (make-instance 'lex-state 
                             :stream stream
                             :start start
                             :captures nil
                             :newline (or (zerop start)
                                          (char= (char s (1- start)) #\newline)))))
      (when (funcall (re-expression re) st)
        (let ((end-pos (file-position stream)))
          (when (and (> end-pos start)
                     (or (= end-pos end)
                         (not exact)))
            (make-instance 're-match
                           :start-pos start
                           :end-pos end-pos
                           :captures (reduce-captures s (lex-captures st))
                           :match (subseq s start end-pos))))))))

(defun find-re (re s &key (start 0) (end (length s)) all)
  "Find a regexp pattern match somewhere in a string."
  (if (not all)
      (loop :for i :from start :below end :do
        (let ((match (match-re re s :start i :end end :exact nil)))
          (when match
            (return match))))
    (loop :with i := start
          :for match := (find-re re s :start i :end end)
          :while match
          :collect (prog1
                       match
                     (setf i (match-pos-end match))))))

(defun split-re (re s &key (start 0) (end (length s)) all coalesce-seps)
  "Split a string into one or more strings by regexp pattern match."
  (if (not all)
      (let ((match (find-re re s :start start :end end)))
        (if (null match)
            (subseq s start end)
          (values (subseq s start (match-pos-start match))
                  (subseq s (match-pos-end match) end))))
    (let* ((hd (list nil)) (tl hd) (pos 0))
      (do ((m (find-re re s :start start :end end)
              (find-re re s :start pos :end end)))
          ((null m)
           (unless (and coalesce-seps (= pos (length s)))
             (rplacd hd (list (subseq s pos))))
           (rest tl))
        (let ((split (subseq s pos (match-pos-start m))))
          (unless (and coalesce-seps (zerop (length split)))
            (setf hd (cdr (rplacd hd (list split)))))
          (setf pos (match-pos-end m)))))))

(defun replace-re (re with s &key (start 0) (end (length s)) all)
  "Replace patterns found within a string with a new value."
  (let ((matches (find-re re s :start start :end end :all all)))
    (unless all
      (setf matches (when matches (list matches))))
    (with-output-to-string (rep nil :element-type 'character)
      (let ((pos 0))
        (loop :for match :in matches
              :do (progn
                    (princ (subseq s pos (match-pos-start match)) rep)
                    (princ (cond
                            ((functionp with) (funcall with match))
                            ((stringp with) (string with))
                            (t (error "~a is not a string or function." with)))
                           rep)
                    (setf pos (match-pos-end match))))
        (princ (subseq s pos) rep)))))

(defun next (st pred)
  "Read the next character, update the pos, test against predicate."
  (let ((c (read-char (lex-stream st) nil nil)))
    (if (funcall pred c)
        c
      (when c
        (unread-char c (lex-stream st))))))

(defmacro def-lex-state ((st &rest slots) &body body)
  "Generate a parse combinator function."
  `#'(lambda (,st)
       (when ,st
         (with-slots ,slots
             ,st
           (progn ,@body)))))

(defun bind (&rest ps)
  "Bind parse combinators together to compose a new combinator."
  (def-lex-state (st)
    (dolist (p ps st)
      (unless (funcall p st)
        (return)))))

(defun capture (p)
  "Push a capture of a combinator onto the lex state."
  (def-lex-state (st stream captures)
    (let ((old-captures captures) (start-pos (file-position stream)))
      (setf captures nil)
        
      ;; run the sub-expression with a new capture array
      (let ((match (when (funcall p st)
                     (make-instance 're-match
                                    :captures captures
                                    :start-pos start-pos
                                    :end-pos (file-position stream)))))
        (prog1
            match
          (push match old-captures)
          
          ;; restore the old capture array, but with the new match added
          (setf captures old-captures))))))

(defun either (p1 p2)
  "Try one parse combinator, if it fails, try another."
  (def-lex-state (st stream captures)
    (let ((pos (file-position stream))
          (caps captures))
      (or (funcall p1 st)
          (progn
            (setf captures caps)
            (file-position stream pos)
            (funcall p2 st))))))

(defun any-char (&key match-newline-p)
  "Expect a non-eoi character."
  (def-lex-state (st)
    (next st #'(lambda (x)
                 (and x (if match-newline-p 
                            t 
                          (null (member x '(#\return #\linefeed)))))))))

(defun eol (&key (match-newline-p t))
  "End of file or line."
  (def-lex-state (st)
    (let ((x (next st #'identity)))
      (or (null x) (and match-newline-p (char= x #\newline))))))

(defun newline (&key (match-newline-p t))
  "Start of file or line."
  (def-lex-state (st)
    (or (zerop (lex-start st)) (and match-newline-p (lex-newline st)))))

(defun ch (c &key case-fold)
  "Match an exact character."
  (let ((test (if case-fold #'unicode-char-equal #'char=)))
    (def-lex-state (st)
      (next st #'(lambda (x)
                   (and x (funcall test x c)))))))

(defun one-of (cs &key case-fold)
  "Match any character from a set."
  (let ((test (if case-fold #'unicode-char-equal #'char=)))
    (def-lex-state (st)
      (next st #'(lambda (x)
                   (and x (find x cs :test test)))))))

(defun none-of (cs &key case-fold)
  "Match any character not in a set."
  (let ((test (if case-fold #'unicode-char-equal #'char=)))
    (def-lex-state (st)
      (next st #'(lambda (x)
                   (and x (not (find x cs :test test))))))))

(defun maybe (p)
  "Optionally match a parse combinator."
  (def-lex-state (st stream)
    (let ((pos (file-position stream)))
      (if (funcall p st)
          t
        (file-position stream pos)))))

(defun many (p)
  "Match a parse combinator zero or more times."
  (def-lex-state (st)
    (do () ((null (funcall p st)) st))))

(defun many-til (p term)
  "Match a parse combinator many times until a terminal."
  (def-lex-state (st)
    (do ()
        ((funcall term st) t)
      (unless (funcall p st)
        (return nil)))))

(defun many1 (p)
  "Match a parse combinator one or more times."
  (bind p (many p)))

(defun between (b1 b2 &key match-newline-p)
  "Match everything between two characters."
  (bind b1 (many-til (any-char :match-newline-p match-newline-p) b2)))
