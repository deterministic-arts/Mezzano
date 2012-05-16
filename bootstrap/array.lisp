;;;; array.lisp

(in-package "SYSTEM.INTERNALS")

(deftype simple-vector (&optional size)
  `(simple-array t (,size)))

(deftype vector (&optional element-type size)
  `(array ,element-type (,size)))

(deftype simple-bit-vector (&optional size)
  `(simple-array bit (,size)))

(deftype bit-vector (&optional size)
  `(vector bit ,size))

(defparameter *specialized-array-types*
  '(bit
    (unsigned-byte 2)
    (unsigned-byte 4)
    (unsigned-byte 8)
    (unsigned-byte 16)
    (unsigned-byte 32)
    (unsigned-byte 64)
    (signed-byte 1)
    (signed-byte 2)
    (signed-byte 4)
    (signed-byte 8)
    (signed-byte 16)
    (signed-byte 32)
    (signed-byte 64)
    base-char
    character
    single-float
    double-float
    long-float
    (complex single-float)
    (complex double-float)
    (complex long-float)
    t)
  "A list of specialized array types supported by the runtime.
This must be sorted from most-specific to least-specific.")

(defun upgraded-array-element-type (typespec &optional environment)
  (dolist (type *specialized-array-types* 't)
    (when (subtypep typespec type environment)
      (return type))))

(defun arrayp (object)
  (or (%array-header-p object)
      (%simple-array-p object)))
(setf (get 'array 'type-symbol) 'arrayp)

(defun adjustable-array-p (array)
  (check-type array array)
  (%array-header-p array))

(defun vectorp (object)
  (or (and (%array-header-p object)
	   (integerp (%array-header-dimensions object)))
      (%simple-array-p object)))
(setf (get 'vector 'type-symbol) 'vectorp)

(defun bit-vector-p (object)
  (and (vectorp object)
       (eql (array-element-type object) 'bit)))
(setf (get 'bit-vector 'type-symbol) 'bit-vector-p)

(defun make-simple-array (length &optional (element-type 't) area (initial-element nil initial-element-p))
  (let ((real-element-type (upgraded-array-element-type element-type)))
    (when (and (eql real-element-type 'character)
               (not initial-element-p))
      ;; Character arrays are stored as 32-bit values WITH tags. %ALLOC-CLEAR
      ;; clears to 0, which would cause uninitialized slots to contain fixnums
      ;; so here we force an initialization.
      (setf initial-element (code-char 0)
            initial-element-p t))
    (cond (initial-element-p
	   (unless (typep initial-element element-type)
	     (error 'type-error :expected-type element-type :datum initial-element))
	   (%allocate-and-fill-array length real-element-type initial-element area))
	  (t (%allocate-and-clear-array length real-element-type area)))))

(defun initialize-from-sequence (array sequence)
  "Fill an array using a sequence."
  (case (array-rank array)
    (0 (setf (aref array) sequence))
    (1 (when (/= (array-dimension array 0) (length sequence))
	 (error "Malformed :INITIAL-CONTENTS: Dimension of axis 0 is ~S but ~S is ~S long."
		(array-dimension array 0) sequence (length sequence)))
       (cond ((listp sequence)
	      (let ((i 0))
		(dolist (e sequence)
		  (setf (aref array i) e)
		  (incf i))))
	     (t (dotimes (i (array-dimension array 0))
		  (setf (aref array i) (aref sequence i))))))
    (t (error "TODO: :INITIAL-CONTENTS for multidimensional arrays."))))

(define-compiler-macro aref (&whole whole array &rest subscripts)
  (case (length subscripts)
    (1 `(aref-1 ,array ,(first subscripts)))
    (2 `(aref-2 ,array ,(first subscripts) ,(second subscripts)))
    (t whole)))

(define-compiler-macro (setf aref) (&whole whole value array &rest subscripts)
  (case (length subscripts)
    (1 `(funcall #'(setf aref-1) ,value ,array ,(first subscripts)))
    (2 `(funcall #'(setf aref-2) ,value ,array ,(first subscripts) ,(second subscripts)))
    (t whole)))

(defun make-array (dimensions &key
		   (element-type t)
		   (initial-element nil initial-element-p)
		   (initial-contents nil initial-contents-p)
		   adjustable
		   fill-pointer
		   displaced-to displaced-index-offset
                   memory
                   area)
  ;; (n) => n
  (when (and (consp dimensions)
	     (null (rest dimensions)))
    (setf dimensions (first dimensions)))
  (when (and initial-element-p initial-contents-p)
    (error "Cannot supply :INITIAL-ELEMENT and :INITIAL-CONTENTS."))
  (when (and displaced-to (or initial-element-p initial-contents-p))
    (error "Cannot use :INITIAL-ELEMENT or :INITIAL-CONTENTS with a displaced array."))
  (when (and (not displaced-to) displaced-index-offset)
    (error "Non-NIL :DISPLACED-INDEX-OFFSET with NIL :DISPLACED-TO."))
  (when fill-pointer
    (unless (integerp dimensions)
      (error ":FILL-POINTER is not valid on multidimensional arrays."))
    (when (eql fill-pointer 't)
      (setf fill-pointer dimensions))
    (unless (integerp fill-pointer)
      (error "Invalid :FILL-POINTER ~S." fill-pointer))
    (unless (<= 0 fill-pointer dimensions)
      (error "Fill-pointer ~S out of vector bounds. Should non-negative and <=~S." fill-pointer dimensions)))
  (when (and memory displaced-to)
    (error ":MEMORY and :DISPLACED-TO are mutually exclusive."))
  (cond ((and (integerp dimensions)
	      (not adjustable)
	      (not fill-pointer)
	      (not displaced-to)
              (not memory))
	 ;; Create a simple 1D array.
	 (let ((array (if initial-element-p
			  (make-simple-array dimensions element-type area initial-element)
			  (make-simple-array dimensions element-type area))))
	   (when initial-contents
	     (initialize-from-sequence array initial-contents))
	   array))
	(displaced-to
         (unless displaced-index-offset
           (setf displaced-index-offset 0))
         (%make-array-header dimensions fill-pointer displaced-index-offset displaced-to area))
	((and (not (integerp dimensions))
	      (endp dimensions))
	 (error "TODO: 0D arrays."))
        (memory
         ;; Element types must be exact matches.
         (when (not (member element-type *specialized-array-types*
                            :test (lambda (x y) (and (subtypep x y) (subtypep y x)))))
           (error "Element type ~S is not supported for memory arrays." element-type))
         (check-type memory fixnum)
         (let ((array (%make-array-header dimensions fill-pointer element-type memory area)))
           (when (or initial-element-p initial-contents-p)
             (error "TODO: Initialization of memory arrays."))
           array))
	(t (let* ((total-size (if (integerp dimensions)
				  dimensions
				  (apply #'* dimensions)))
		  (backing-array (if initial-element-p
				     (make-simple-array total-size element-type area initial-element)
				     (make-simple-array total-size element-type area)))
		  (array (%make-array-header dimensions fill-pointer nil backing-array area)))
	     (when initial-contents
	       (initialize-from-sequence array initial-contents))
	     array))))

(defun adjust-array (array new-dimensions &key
		     (element-type (array-element-type array))
		     (initial-element nil initial-element-p)
		     fill-pointer)
  (unless (equal element-type (array-element-type array))
    (error "Cannot convert array ~S to different element-type ~S from ~S."
	   array element-type (array-element-type array)))
  (when (and (consp new-dimensions)
	     (null (rest new-dimensions)))
    (setf new-dimensions (first new-dimensions)))
  (when fill-pointer
    (unless (integerp new-dimensions)
      (error ":FILL-POINTER is only valid with vectors."))
    (when (eql fill-pointer 't)
      (setf fill-pointer new-dimensions))
    (unless (integerp fill-pointer)
      (error "Invalid :FILL-POINTER ~S." fill-pointer))
    (unless (<= 0 fill-pointer dimensions)
      (error "Fill-pointer ~S out of vector bounds. Should non-negative and <=~S." fill-pointer dimensions)))
  (unless (and (vectorp array)
	       (integerp new-dimensions))
    (error "TODO: adjust-array on non-vectors."))
  (when (and (array-has-fill-pointer-p array)
	     (not fill-pointer)
	     (< new-dimensions (fill-pointer array)))
    (error "Fill-pointer ~S on array ~S is larger than the new size ~S."
	   (fill-pointer array) array new-dimensions))
  (if (%array-header-p array)
      (cond ((null (%array-header-info array))
	     (let ((old-array (%array-header-storage array))
		   (new-array (if initial-element-p
				  (make-simple-array new-dimensions element-type nil initial-element)
				  (make-simple-array new-dimensions element-type nil))))
	       (dotimes (i (min new-dimensions (array-dimension old-array 0)))
		 (setf (aref new-array i) (aref old-array i)))
	       (setf (%array-header-dimensions array) new-dimensions
		     (%array-header-storage array) new-array))
	     array)
	    (t (error "TODO: Adjusting unusual array ~S." array)))
      (let ((new-array (if initial-element-p
			   (make-simple-array new-dimensions element-type nil initial-element)
			   (make-simple-array new-dimensions element-type nil))))
	(dotimes (i (min new-dimensions (array-dimension old-array 0)))
	  (setf (aref new-array i) (aref old-array i)))
	new-array)))

(defun array-rank (array)
  (check-type array array)
  (cond ((%array-header-p array)
	 (if (integerp (%array-header-dimensions array))
	     1
	     (list-length (%array-header-dimensions array))))
	(t 1)))

(defun array-dimensions (array)
  (check-type array array)
  (cond ((%array-header-p array)
	 (if (integerp (%array-header-dimensions array))
	     (list (%array-header-dimensions array))
	     (%array-header-dimensions array)))
	(t (list (array-dimension array 0)))))

(defun array-dimension (array axis-number)
  (check-type array array)
  (check-type axis-number (integer 0) "a non-negative integer")
  (cond ((%array-header-p array)
	 (let* ((dims (%array-header-dimensions array))
		(rank (if (integerp dims)
			  1
			  (list-length dims))))
	   (when (>= axis-number rank)
	     (error "Axis ~S exceeds array rank ~S." axis-number rank))
	   (if (integerp dims)
	       dims
	       (nth axis-number dims))))
	(t (unless (zerop axis-number)
	     (error "Axis ~S exceeds array rank 1." axis-number))
	   (%simple-array-length array))))

(defun array-total-size (array)
  (check-type array array)
  (cond ((%array-header-p array)
	 (if (integerp (%array-header-dimensions array))
	     (%array-header-dimensions array)
	     (apply #'* (%array-header-dimensions array))))
	(t (%simple-array-length array))))

(defun array-displacement (array)
  (check-type array array)
  (if (and (%array-header-p array)
	   (integerp (%array-header-info array)))
      (values (%array-header-storage array)
	      (%array-header-info array))
      (values nil 0)))

(defun array-element-type (array)
  (check-type array array)
  (if (%array-header-p array)
      (cond ((or (null (%array-header-dimensions array))
		 (integerp (%array-header-storage array)))
	     ;; 0D and memory arrays store the type in the info slot.
	     (%array-header-info array))
	    ((%array-header-info array)
	     ;; Displaced arrays inherit the type of the array they displace on.
	     (array-element-type (%array-header-storage array)))
	    (t ;; Normal arrays use the type of their storage simple array.
	     (%simple-array-element-type (%array-header-storage array))))
      (%simple-array-element-type array)))

(defun array-has-fill-pointer-p (array)
  (check-type array array)
  (when (%array-header-p array)
    (%array-header-fill-pointer array)))

(defun array-in-bounds-p (array &rest subscripts)
  (check-type array array)
  (and (not (some #'minusp subscripts))
       (every #'< subscripts (array-dimensions array))))

(defun array-row-major-index (array &rest subscripts)
  (declare (dynamic-extent subscripts))
  (apply #'+ (maplist (lambda (x y)
			(unless (<= 0 (car x) (1- (car y)))
			  (error "Subscript ~S is invalid for axis, should be non-negative and less than ~S."
				 (car x) (car y)))
			(* (car x) (apply #'* (cdr y))))
		      subscripts
		      (array-dimensions array))))

(defun check-vector-has-fill-pointer (vector)
  (unless (and (%array-header-p vector)
	       (%array-header-fill-pointer vector))
    (error 'simple-type-error
	   :expected-type 'vector
	   :datum vector
	   :format-control "VECTOR ~S is not a VECTOR with a fill-pointer."
	   :format-arguments (list vector))))

(defun fill-pointer (vector)
  (check-vector-has-fill-pointer vector)
  (%array-header-fill-pointer vector))

(defun (setf fill-pointer) (new-value vector)
  (check-type new-value (integer 0))
  ;; Not sure if this should allow adding a fill-pointer to a vector
  ;; that doesn't already have one.
  (check-vector-has-fill-pointer vector)
  (unless (<= 0 new-value (%array-header-dimensions vector))
    (error "New fill-pointer ~S exceeds vector bounds. Should be non-negative and <=~S."
	   new-value (%array-header-dimensions vector)))
  (setf (%array-header-fill-pointer vector) new-value))

(defun vector (&rest objects)
  (declare (dynamic-extent objects))
  (make-array (length objects)
	      :element-type t
	      :initial-contents objects))

(defun %row-major-aref (array index)
  "ROW-MAJOR-AREF with no bounds check."
  (if (%array-header-p array)
      (cond ((null (%array-header-dimensions array))
	     ;; 0D array, value is stored in the storage slot.
	     (%array-header-storage array))
	    ((null (%array-header-info array))
	     ;; Normal array, must be backed by a simple array.
	     (%simple-array-aref (%array-header-storage array) index))
	    ((integerp (%array-header-info array))
	     ;; Displaced array.
	     (row-major-aref (%array-header-storage array) (+ index (%array-header-info array))))
	    (t ;; Direct memory access array.
	     (%memory-aref (%array-header-info array) (%array-header-storage array) index)))
      (%simple-array-aref array index)))

(defun (setf %row-major-aref) (value array index)
  "(SETF ROW-MAJOR-AREF) with no bounds check."
  (if (%array-header-p array)
      (cond ((null (%array-header-dimensions array))
	     ;; 0D array, value is stored in the storage slot.
	     (unless (typep value (%array-header-info array))
	       (error 'type-error
		      :expected-type (%array-header-info array)
		      :datum value))
	     (setf (%array-header-storage array) value))
	    ((null (%array-header-info array))
	     ;; Normal array, must be backed by a simple array.
	     (setf (%simple-array-aref (%array-header-storage array) index) value))
	    ((integerp (%array-header-info array))
	     ;; Displaced array.
	     (setf (row-major-aref (%array-header-storage array) (+ index (%array-header-info array))) value))
	    (t ;; Direct memory access array.
	     (setf (%memory-aref (%array-header-info array) (%array-header-storage array) index) value)))
      (setf (%simple-array-aref array index) value)))

(defun row-major-aref (array index)
  (check-type array array)
  (check-type index (integer 0) "a non-negative integer")
  (let ((total-size (array-total-size array)))
    (when (>= index total-size)
      (error "Row-major index ~S exceeds total size ~S of array ~S." index total-size array))
    (%row-major-aref array index)))

(defun (setf row-major-aref) (value array index)
  (check-type array array)
  (check-type index (integer 0) "a non-negative integer")
  (let ((total-size (array-total-size array)))
    (when (>= index total-size)
      (error "Row-major index ~S exceeds total size ~S of array ~S." index total-size array))
    (setf (%row-major-aref array index) value)))

(defun aref (array &rest subscripts)
  (declare (dynamic-extent subscripts))
  (%row-major-aref array (apply #'array-row-major-index array subscripts)))

(defun (setf aref) (value array &rest subscripts)
  (declare (dynamic-extent subscripts))
  (setf (%row-major-aref array (apply #'array-row-major-index array subscripts)) value))

(defun aref-1 (array index)
  (unless (= (array-rank array) 1)
    (error "Invalid number of indices to array ~S." array))
  (when (>= index (array-dimension array 0))
    (error "Index ~S out of bounds. Must be 0 <= n < ~D~%"
           index (array-dimension array 0)))
  (%row-major-aref array index))

(defun (setf aref-1) (value array index)
  (unless (= (array-rank array) 1)
    (error "Invalid number of indices to array ~S." array))
  (when (>= index (array-dimension array 0))
    (error "Index ~S out of bounds. Must be 0 <= n < ~D~%"
           index (array-dimension array 0)))
  (setf (%row-major-aref array index) value))

(defun aref-2 (array index1 index2)
  (unless (= (array-rank array) 2)
    (error "Invalid number of indices to array ~S." array))
  (when (>= index1 (array-dimension array 0))
    (error "Index ~S out of bounds. Must be 0 <= n < ~D~%"
           index1 (array-dimension array 0)))
  (when (>= index2 (array-dimension array 1))
    (error "Index ~S out of bounds. Must be 0 <= n < ~D~%"
           index2 (array-dimension array 1)))
  (let ((ofs (+ (* index1 (array-dimension array 1)) index2)))
    (%row-major-aref array ofs)))

(defun (setf aref-2) (value array index1 index2)
  (unless (= (array-rank array) 2)
    (error "Invalid number of indices to array ~S." array))
  (when (>= index1 (array-dimension array 0))
    (error "Index ~S out of bounds. Must be 0 <= n < ~D~%"
           index1 (array-dimension array 0)))
  (when (>= index2 (array-dimension array 1))
    (error "Index ~S out of bounds. Must be 0 <= n < ~D~%"
           index2 (array-dimension array 1)))
  (let ((ofs (+ (* index1 (array-dimension array 1)) index2)))
    (setf (%row-major-aref array ofs) value)))

(defun bit (bit-array &rest subscripts)
  (declare (dynamic-extent subscripts))
  (check-type bit-array (array bit))
  (apply #'aref array subscripts))

(defun sbit (bit-array &rest subscripts)
  (declare (dynamic-extent subscripts))
  (check-type bit-array (simple-array bit))
  (apply #'aref array subscripts))

(defun char (string index)
  (cond ((simple-string-p string)
         (schar string index))
        ;; Open-coded check for non-displaced non-simple string-like
        ;; arrays.
        ((and (%array-header-p string)
              (fixnump (%array-header-dimensions string))
              (null (%array-header-info string))
              (simple-string-p (%array-header-storage string)))
         (schar (%array-header-storage string) index))
        (t (check-type string string)
           (aref string index))))

(defun (setf char) (value string index)
  (cond ((simple-string-p string)
         (setf (schar string index) value))
        ;; Open-coded check for non-displaced non-simple string-like
        ;; arrays.
        ((and (%array-header-p string)
              (fixnump (%array-header-dimensions string))
              (null (%array-header-info string))
              (simple-string-p (%array-header-storage string)))
         (setf (schar (%array-header-storage string) index) value))
        (t (check-type string string)
           (setf (aref string index) value))))

(defun vector-pop (vector)
  (check-vector-has-fill-pointer vector)
  (when (zerop (fill-pointer vector))
    (error "Vector ~S is empty." vector))
  (aref vector (decf (fill-pointer vector))))

(defun vector-push (new-element vector)
  "Attempts to set the element of VECTOR designated by its fill-pointer
to NEW-ELEMENT and increments the fill-pointer by one. Returns NIL if the fill-pointer
is too large; otherwise the index of the new element is returned."
  (check-vector-has-fill-pointer vector)
  (let ((fp (fill-pointer vector)))
    (when (< fp (array-dimension vector 0))
      (setf (aref vector fp) new-element)
      (incf (fill-pointer vector))
      fp)))

(defun vector-push-extend (new-element vector &optional (extension (1+ (length vector))))
  "Sets the element of VECTOR designated by its fill-pointer to NEW-ELEMENT, increments
the fill-pointer by one and returns the index of the new element. VECTOR is extended by
at least MIN-EXTENSION if required."
  (check-type extension (integer 1) "a positive integer")
  (check-vector-has-fill-pointer vector)
  (when (>= (fill-pointer vector) (array-dimension vector 0))
    (adjust-array vector (+ (array-dimension vector 0) extension)))
  (vector-push new-element vector))
