(in-package :mgl-bm)

;;;; Chunk

(defclass chunk ()
  ((name :initform (gensym) :initarg :name :reader name)
   (size :initarg :size :reader size)
   (n-stripes :initform 1 :reader n-stripes)
   (nodes
    :type flt-vector :reader nodes
    :documentation "A value for each node in the chunk. First,
activations are put here (weights*inputs) then the mean of the
probability distribution is calculated from the activation and finally
\(optionally) a sample is taken from the probability distribution. All
these values are stored in this vector. This is also where SET-INPUT
is supposed to clamp the values. Note that not only the values in the
matrix but also the matrix object itself can change when the network
is used.")
   (old-nodes
    :type flt-vector :reader old-nodes
    :documentation "The previous value of each node. Used to provide
parallel computation semantics when there are intralayer connections.
Swapped with NODES or MEANS at times.")
   (means
    :type (or flt-vector null) :reader means
    :documentation "Saved values of the means (see SET-MEAN) last
computed.")
   (inputs
    :type (or flt-vector null) :reader inputs
    :documentation "This is where the after method of SET-INPUT saves
the input for later use by RECONSTRUCTION-ERROR, INPUTS->NODES. It is
NIL in CONDITIONING-CHUNKS.")
   (indices-present
    :initform nil :initarg :indices-present :type (or null index-vector)
    :accessor indices-present
    :documentation "NIL or a simple vector of array indices into the
layer's NODES. Need not be ordered. SET-INPUT sets it. Note, that if
it is non-NIL then N-STRIPES must be 1."))
  (:documentation "A chunk is a set of nodes of the same type in a
Boltzmann Machine. This is an abstract base class."))

(declaim (inline nodes*))
(defun nodes* (chunk)
  (the flt-vector (values (nodes chunk))))

(defmethod max-n-stripes ((chunk chunk))
  (/ (length (nodes chunk))
     (size chunk)))

(defmethod striped-array ((chunk chunk))
  (nodes chunk))

(defmethod stripe-start (stripe (chunk chunk))
  (* stripe (size chunk)))

(defmethod stripe-end (stripe (chunk chunk))
  (* (1+ stripe) (size chunk)))

(defmethod print-object ((chunk chunk) stream)
  (pprint-logical-block (stream ())
    (print-unreadable-object (chunk stream :type t)
      (format stream "~S ~:_~S(~S/~S)"
              (ignore-errors (name chunk))
              (ignore-errors (size chunk))
              (ignore-errors (n-stripes chunk))
              (ignore-errors (max-n-stripes chunk)))))
  chunk)

(define-descriptions (chunk chunk)
  name size n-stripes max-n-stripes)

;;; Currently the lisp code handles only the single stripe case and
;;; blas cannot deal with missing values.
(defun check-stripes (chunk)
  (let ((indices-present (indices-present chunk)))
    (assert (or (null indices-present)
                (zerop (length indices-present))
                (= 1 (n-stripes chunk))))))

(defun use-blas-on-chunk-p (chunk)
  (check-stripes chunk)
  ;; there is no missing value support in blas
  (null (indices-present chunk)))

(defun ->chunk (chunk-designator chunks)
  (if (typep chunk-designator 'chunk)
      chunk-designator
      (or (find chunk-designator chunks :key #'name :test #'equal)
          (error "Cannot find chunk ~S." chunk-designator))))

(defvar *current-stripe*)

(defmacro do-stripes ((chunk &optional (stripe (gensym))) &body body)
  (with-gensyms (%chunk)
    `(let ((,%chunk ,chunk))
       (check-stripes ,%chunk)
       (dotimes (,stripe (the index (n-stripes ,%chunk)))
         (let ((*current-stripe* ,stripe))
           ,@body)))))

(defmacro do-chunk ((index chunk) &body body)
  "Iterate over the indices of nodes of CHUNK skipping missing ones."
  (with-gensyms (%chunk %indices-present %size)
    `(let* ((,%chunk ,chunk)
            (,%indices-present (indices-present ,%chunk)))
       (if ,%indices-present
           (locally (declare (type index-vector ,%indices-present))
             (loop for ,index across ,%indices-present
                   do (progn ,@body)))
           (let ((,%size (size ,%chunk)))
             (declare (type index ,%size))
             (loop for ,index fixnum
                   upfrom (locally (declare (optimize (speed 1)))
                            (the index (* *current-stripe* ,%size)))
                   below (locally (declare (optimize (speed 1)))
                           (the index (+ ,%size (* *current-stripe* ,%size))))
                   do ,@body))))))

(defun fill-chunk (chunk value &key allp)
  (declare (type flt value))
  (if (or (null (indices-present chunk)) allp)
      (fill! value (nodes chunk))
      (let ((nodes (nodes* chunk)))
        (declare (optimize (speed 3) #.*no-array-bounds-check*))
        (do-stripes (chunk)
          (do-chunk (i chunk)
            (setf (aref nodes i) value))))))

(defun zero-chunk (chunk)
  (fill-chunk chunk #.(flt 0)))

(defun sum-chunk-nodes-and-old-nodes (chunk node-weight old-node-weight)
  (unless (eq (nodes chunk) (old-nodes chunk))
    (lla:scal! (flt node-weight) (nodes chunk))
    (lla:scal! (flt old-node-weight) (old-nodes chunk))
    (lla:axpy! 1 (old-nodes chunk) (nodes chunk))))

(defun sum-nodes-and-old-nodes (chunks node-weight old-node-weight)
  (map nil (lambda (chunk)
             (sum-chunk-nodes-and-old-nodes chunk node-weight old-node-weight))
       chunks))

(defclass conditioning-chunk (chunk) ()
  (:documentation "Nodes in CONDITIONING-CHUNK never change their
values on their own so they are to be clamped. Including this chunk in
the visible layer allows `conditional' RBMs."))

(defun conditioning-chunk-p (chunk)
  (typep chunk 'conditioning-chunk))

(defgeneric copy-nodes (chunk)
  (:method ((chunk chunk))
    (alexandria:copy-array (nodes chunk)))
  (:method ((chunk conditioning-chunk))
    (nodes chunk)))

(defgeneric resize-chunk (chunk size max-n-stripes)
  (:method ((chunk chunk) size max-n-stripes)
    (unless (and (slot-boundp chunk 'nodes)
                 (= size (size chunk))
                 (= max-n-stripes (max-n-stripes chunk)))
      (setf (slot-value chunk 'size) size)
      (setf (slot-value chunk 'nodes)
            (make-flt-array (* max-n-stripes size)))
      (setf (slot-value chunk 'means)
            (copy-nodes chunk))
      (setf (slot-value chunk 'old-nodes)
            (copy-nodes chunk))
      (setf (slot-value chunk 'inputs)
            (if (typep chunk 'conditioning-chunk)
                nil
                (make-flt-array (* max-n-stripes size)))))))

(defmethod set-n-stripes (n-stripes (chunk chunk))
  (assert (<= n-stripes (max-n-stripes chunk)))
  (setf (slot-value chunk 'n-stripes) n-stripes))

(defmethod set-max-n-stripes (max-n-stripes (chunk chunk))
  (resize-chunk chunk (size chunk) max-n-stripes)
  max-n-stripes)

(defmethod initialize-instance :after ((chunk chunk)
                                       &key (size 1) (max-n-stripes 1)
                                       &allow-other-keys)
  (resize-chunk chunk size max-n-stripes))

(defclass constant-chunk (conditioning-chunk)
  ((default-value :initform #.(flt 1) :reader default-value))
  (:documentation "A special kind of CONDITIONING-CHUNK whose NODES
are always DEFAULT-VALUE. This conveniently allows biases in the
opposing layer."))

(define-descriptions (chunk conditioning-chunk :inheritp t)
  default-value)

(defmethod resize-chunk ((chunk constant-chunk) size max-n-stripes)
  (call-next-method)
  (fill-chunk chunk (default-value chunk) :allp t))

(defclass sigmoid-chunk (chunk) ()
  (:documentation "Nodes in a sigmoid chunk have two possible samples:
0 and 1. The probability of a node being on is given by the sigmoid of
its activation."))

(defclass gaussian-chunk (chunk) ()
  (:documentation "Nodes are real valued. The sample of a node is its
activation plus guassian noise of unit variance."))

(defclass normalized-group-chunk (chunk)
  ((scale
    :initform #.(flt 1) :type (or flt flt-vector)
    :initarg :scale :accessor scale
    :documentation "The sum of the means after normalization. Can be
changed during training, for instance when clamping. If it is a vector
then its length must be MAX-N-STRIPES which is automatically
maintained when changing the number of stripes.")
   (group-size
    :initform (error "GROUP-SIZE must be specified.")
    :initarg :group-size
    :reader group-size))
  (:documentation "Means are normalized to SCALE within node groups of
GROUP-SIZE."))

(define-descriptions (chunk normalized-group-chunk :inheritp t)
  scale group-size)

(defmethod resize-chunk ((chunk normalized-group-chunk) size max-n-stripes)
  (call-next-method)
  (when (and (typep (scale chunk) 'flt-vector)
             (/= (max-n-stripes chunk) (length (scale chunk))))
    (setf (scale chunk) (make-flt-array (max-n-stripes chunk)))))

(defclass exp-normalized-group-chunk (normalized-group-chunk) ()
  (:documentation "Means are normalized (EXP ACTIVATION)."))

(defclass softmax-chunk (exp-normalized-group-chunk) ()
  (:documentation "Binary units with normalized (EXP ACTIVATION)
firing probabilities representing a multinomial distribution. That is,
samples have exactly one 1 in each group of GROUP-SIZE."))

(defclass constrained-poisson-chunk (exp-normalized-group-chunk) ()
  (:documentation "Poisson units with normalized (EXP ACTIVATION) means."))

(defclass temporal-chunk (conditioning-chunk)
  ((hidden-source-chunk
    :initarg :hidden-source-chunk
    :reader hidden-source-chunk)
   (next-node-inputs :reader next-node-inputs)
   (has-inputs-p :initform nil :reader has-inputs-p))
  (:documentation "After a SET-HIDDEN-MEAN, the means of
HIDDEN-SOURCE-CHUNK are stored in NEXT-NODE-INPUTS and on the next
SET-INPUT copied onto NODES. If there are multiple SET-HIDDEN-MEAN
calls between two SET-INPUT calls then only the first set of values
are remembered."))

(defmethod resize-chunk ((chunk temporal-chunk) size max-n-stripes)
  (call-next-method)
  (unless (and (slot-boundp chunk 'next-node-inputs)
               (= (length (next-node-inputs chunk))
                  (length (nodes chunk))))
    (setf (slot-value chunk 'next-node-inputs)
          (make-flt-array (* size max-n-stripes)))))

(defun copy-chunk-nodes (chunk from to)
  (declare (type flt-vector from to))
  (unless (eq from to)
    (if (null (indices-present chunk))
        (lla:copy! from to)
        (locally (declare (optimize (speed 3)))
          (do-stripes (chunk)
            (do-chunk (i chunk)
              (setf (aref to i) (aref from i))))))))

(defun add-chunk-nodes (chunk from to)
  (declare (type flt-vector from to))
  (unless (eq from to)
    (if (null (indices-present chunk))
        (lla:axpy! 1 from to)
        (locally (declare (optimize (speed 3)))
          (do-stripes (chunk)
            (do-chunk (i chunk)
              (incf (aref to i) (aref from i))))))))

(defun maybe-remember (chunk)
  (unless (has-inputs-p chunk)
    (let ((hidden (hidden-source-chunk chunk)))
      (assert (null (indices-present hidden)))
      (copy-chunk-nodes chunk (nodes hidden) (next-node-inputs chunk))
      (setf (slot-value chunk 'has-inputs-p) t))))

(defun maybe-use-remembered (chunk)
  (when (has-inputs-p chunk)
    (setf (indices-present chunk) nil)
    (copy-chunk-nodes chunk (next-node-inputs chunk) (nodes chunk))
    (setf (slot-value chunk 'has-inputs-p) nil)))

(defun nodes->means (chunk)
  (let ((means (means chunk)))
    (when means
      (copy-chunk-nodes chunk (nodes chunk) means))))

(defun visible-nodes->means (bm)
  (mapc #'nodes->means (visible-chunks bm)))

(defgeneric set-chunk-mean (chunk)
  (:documentation "Set NODES of CHUNK to the means of the probability
distribution. When called NODES contains the activations.")
  (:method :after ((chunk chunk))
    (nodes->means chunk))
  (:method ((chunk conditioning-chunk)))
  (:method ((chunk sigmoid-chunk))
    (let ((nodes (nodes* chunk)))
      (do-stripes (chunk)
        (do-chunk (i chunk)
          (setf (aref nodes i)
                (sigmoid (aref nodes i)))))))
  (:method ((chunk gaussian-chunk))
    ;; nothing to do: NODES already contains the activation
    )
  (:method ((chunk normalized-group-chunk))
    ;; NODES is already set up, only normalization within groups of
    ;; GROUP-SIZE remains.
    (let ((nodes (nodes* chunk))
          (scale (scale chunk))
          (group-size (group-size chunk)))
      (declare (type (or flt flt-vector) scale)
               (type index group-size))
      (assert (zerop (mod (size chunk) group-size)))
      (do-stripes (chunk stripe)
        (let ((scale (if (typep scale 'flt) scale (aref scale stripe))))
          (when (/= 0 scale)
            (do-chunk (i chunk)
              ;; this assumes that nodes in the same group have values at
              ;; the same time
              (when (zerop (mod i group-size))
                (let ((sum #.(flt 0)))
                  (declare (type flt sum) (optimize (speed 3)))
                  (loop for j upfrom i below (+ i group-size)
                        do (incf sum (aref nodes j)))
                  (when (/= 0 sum)
                    (setq sum (/ sum scale))
                    (loop for j upfrom i below (+ i group-size)
                          do (setf (aref nodes j)
                                   (/ (aref nodes j) sum))))))))))))
  (:method ((chunk exp-normalized-group-chunk))
    (let ((nodes (nodes* chunk))
          (scale (scale chunk))
          (group-size (group-size chunk)))
      (declare (type (or flt flt-vector) scale)
               (type index group-size))
      (assert (zerop (mod (size chunk) group-size)))
      (do-stripes (chunk stripe)
        (let ((scale (if (typep scale 'flt) scale (aref scale stripe))))
          (when (/= 0 scale)
            (do-chunk (i chunk)
              ;; this assumes that nodes in the same group have values at
              ;; the same time
              (when (zerop (mod i group-size))
                (let ((max most-negative-flt))
                  (declare (type flt max))
                  ;; It's more stable numerically to subtract the max
                  ;; from elements in the group before exponentiating.
                  (loop for j upfrom i below (+ i group-size)
                        do (setq max (max max (aref nodes j))))
                  (let ((sum #.(flt 0)))
                    (declare (type flt sum) (optimize (speed 3)))
                    (loop for j upfrom i below (+ i group-size)
                          do (incf sum (exp (- (aref nodes j) max))))
                    (when (/= 0 sum)
                      (setq sum (/ sum scale))
                      (loop for j upfrom i below (+ i group-size)
                            do (setf (aref nodes j)
                                     (/ (exp (- (aref nodes j) max))
                                        sum))))))))))))))

(defgeneric sample-chunk (chunk)
  (:documentation "Sample from the probability distribution of CHUNK
whose means are in NODES.")
  (:method ((chunk conditioning-chunk)))
  (:method ((chunk sigmoid-chunk))
    (let ((nodes (nodes* chunk)))
      (do-stripes (chunk)
        (do-chunk (i chunk)
          (setf (aref nodes i)
                (binarize-randomly (aref nodes i)))))))
  (:method ((chunk gaussian-chunk))
    (let ((nodes (nodes* chunk)))
      (do-stripes (chunk)
        (do-chunk (i chunk)
          (setf (aref nodes i)
                (+ (aref nodes i)
                   (gaussian-random-1)))))))
  (:method ((chunk softmax-chunk))
    (let ((nodes (nodes* chunk))
          (group-size (group-size chunk)))
      (declare (type index group-size)
               (optimize (speed 3)))
      (do-stripes (chunk)
        (do-chunk (i chunk)
          (when (zerop (mod i group-size))
            (let ((x (random #.(flt 1))))
              (declare (type flt x))
              (loop for j upfrom i below (+ i group-size) do
                (when (minusp (decf x (aref nodes j)))
                  (fill nodes #.(flt 0) :start i :end (+ i group-size))
                  (setf (aref nodes j) #.(flt 1))
                  (return)))))))))
  (:method ((chunk constrained-poisson-chunk))
    (let ((nodes (nodes* chunk)))
      (do-stripes (chunk)
        (do-chunk (i chunk)
          (setf (aref nodes i) (flt (poisson-random (aref nodes i)))))))))


;;;; Cloud

(defvar *versions* ())

(defun version (obj)
  (or (cdr (find obj *versions* :key #'car))
      (gensym)))

(defmacro with-versions ((version objects) &body body)
  (let ((%version (gensym)))
    `(let* ((,%version ,version)
            (*versions* (append (mapcar (lambda (object)
                                          (cons object ,%version))
                                        ,objects)
                                *versions*)))
       ,@body)))

(defclass cloud ()
  ((name :initarg :name :reader name)
   (chunk1 :type chunk :initarg :chunk1 :reader chunk1)
   (chunk2 :type chunk :initarg :chunk2 :reader chunk2)
   (scale1
    :type flt :initform #.(flt 1) :initarg :scale1 :reader scale1
    :documentation "When CHUNK1 is being activated count activations
coming from this cloud multiplied by SCALE1.")
   (scale2
    :type flt :initform #.(flt 1) :initarg :scale2 :reader scale2
    :documentation "When CHUNK2 is being activated count activations
coming from this cloud multiplied by SCALE2.")
   (cached-version1 :initform (gensym) :accessor cached-version1)
   (cached-version2 :initform (gensym) :accessor cached-version2)
   (cached-activations1
    :initform nil
    :type (or flt-vector null) :reader cached-activations1)
   (cached-activations2
    :initform nil
    :type (or flt-vector null) :reader cached-activations2))
  (:documentation "A set of connections between two chunks. The chunks
may be the same, be both visible or both hidden subject to constraints
imposed by the type of boltzmann machine the cloud is part of."))

(defmethod print-object ((cloud cloud) stream)
  (pprint-logical-block (stream ())
    (print-unreadable-object (cloud stream :type t)
      (when (slot-boundp cloud 'name)
        (format stream "~S" (ignore-errors (name cloud))))))
  cloud)

(define-descriptions (cloud cloud)
  name chunk1 chunk2)

(defmethod set-n-stripes (n-stripes (cloud cloud)))
(defmethod set-max-n-stripes (max-n-stripes (cloud cloud)))

(defun conditioning-cloud-p (cloud)
  (or (conditioning-chunk-p (chunk1 cloud))
      (conditioning-chunk-p (chunk2 cloud))))

(defun activate-cloud (cloud reversep &key
                       (from-fn #'old-nodes) (to-fn #'nodes))
  "From CHUNK1 calculate the activations of CHUNK2 and _add_ them to
CHUNK2. If REVERSEP then swap the roles of the chunks. FROM-FN and
TO-FN are the accessors to use to get the nodes value arrays (one of
#'NODES, #'OLD-NODES, #'MEANS. In the simplest case it adds
weights (of CLOUD) * OLD-NODES (of CHUNK1) to the nodes of the hidden
chunk."
  (multiple-value-bind (from-chunk to-chunk)
      (if reversep
          (values (chunk2 cloud) (chunk1 cloud))
          (values (chunk1 cloud) (chunk2 cloud)))
    (activate-cloud* cloud reversep
                     from-chunk to-chunk
                     (funcall from-fn from-chunk)
                     (funcall to-fn to-chunk))))

(defgeneric activate-cloud* (cloud reversep from-chunk to-chunk
                             from-matrix to-matrix)
  (:documentation "Like ACTIVATE-CLOUD but without keyword parameters."))

(defgeneric accumulate-cloud-statistics (trainer bm cloud multiplier)
  (:documentation "Take the accumulator of TRAINER that corresponds to
CLOUD and add MULTIPLIER times the cloud statistics of [persistent]
contrastive divergence."))

(defun hijack-means-to-activation (chunks clouds)
  "Set NODES of CHUNKS to the activations calculated from CLOUDS. Skip
chunks that don't need activations. If ADDP don't zero NODES first,
but add to it."
  ;; Zero activations or copy cached activations coming from
  ;; conditioning chunks.
  (dolist (chunk chunks)
    (unless (conditioning-chunk-p chunk)
      (zero-chunk chunk)))
  (dolist (cloud clouds)
    (when (and (member (chunk2 cloud) chunks)
               (not (conditioning-chunk-p (chunk2 cloud))))
      (activate-cloud cloud nil))
    (when (and (member (chunk1 cloud) chunks)
               (not (eq (chunk1 cloud) (chunk2 cloud)))
               (not (conditioning-chunk-p (chunk1 cloud))))
      (activate-cloud cloud t))))

;;; See if both ends of CLOUD are among CHUNKS.
(defun both-cloud-ends-in-p (cloud chunks)
  (and (member (chunk1 cloud) chunks)
       (member (chunk2 cloud) chunks)))

(defgeneric zero-weight-to-self (cloud)
  (:documentation "In a BM W_{i,i} is always zero."))

(defmethod activate-cloud* :before (cloud reversep from-chunk to-chunk
                                    from-matrix to-matrix)
  (zero-weight-to-self cloud))

(defun ensure-array-large-enough (array prototype)
  (let ((size (array-total-size prototype)))
    (if (and array (<= size (array-total-size array)))
        array
        (make-flt-array size))))

(defmethod activate-cloud* :around (cloud reversep from-chunk to-chunk
                                    from-matrix to-matrix)
  (let ((chunk1 (chunk1 cloud))
        (chunk2 (chunk2 cloud)))
    (cond (reversep
           (let ((version (version chunk2)))
             (unless (eq version (cached-version1 cloud))
               (setf (slot-value cloud 'cached-activations1)
                     (ensure-array-large-enough (cached-activations1 cloud)
                                                (nodes chunk1)))
               (fill! 0 (cached-activations1 cloud))
               (call-next-method cloud reversep
                                 from-chunk to-chunk
                                 from-matrix (cached-activations1 cloud))
               (setf (cached-version1 cloud) version)))
           (add-chunk-nodes (chunk1 cloud)
                            (cached-activations1 cloud)
                            to-matrix))
          (t
           (let ((version (version chunk1)))
             (unless (eq version (cached-version2 cloud))
               (setf (slot-value cloud 'cached-activations2)
                     (ensure-array-large-enough (cached-activations2 cloud)
                                                (nodes chunk2)))
               (fill! 0 (cached-activations2 cloud))
               (call-next-method cloud reversep
                                 from-chunk to-chunk
                                 from-matrix (cached-activations2 cloud))
               (setf (cached-version2 cloud) version)))
           (add-chunk-nodes (chunk2 cloud)
                            (cached-activations2 cloud)
                            to-matrix)))))

;;; Return the chunk of CLOUD that's among CHUNKS and the other chunk
;;; of CLOUD as the second value.
(defun cloud-chunk-among-chunks (cloud chunks)
  (cond ((member (chunk1 cloud) chunks)
         (values (chunk1 cloud) (chunk2 cloud)))
        ((member (chunk2 cloud) chunks)
         (values (chunk2 cloud) (chunk1 cloud)))
        (t
         (values nil nil))))

(defun cloud-between-chunks-p (cloud chunks1 chunks2)
  (or (and (member (chunk1 cloud) chunks1)
           (member (chunk2 cloud) chunks2))
      (and (member (chunk1 cloud) chunks2)
           (member (chunk2 cloud) chunks1))))


;;;; Full cloud

(defclass full-cloud (cloud)
  ((weights
    :type flt-vector :initarg :weights :reader weights
    :documentation "A chunk is represented as a row vector
\(disregarding the multi-striped case). If the visible chunk is 1xN
and the hidden is 1xM then the weight matrix is NxM. Hidden = hidden +
weights * visible. Visible = visible + weights^T * hidden.")))

(defun norm (matrix)
  (sqrt (loop for i below (array-total-size matrix)
              sum (expt (row-major-aref matrix i) 2))))

(defun full-cloud-norm (cloud)
  (norm (weights cloud)))

(defun format-full-cloud-norm (cloud)
  (format nil "~,5E" (full-cloud-norm cloud)))

(define-descriptions (cloud full-cloud :inheritp t)
  (norm (format-full-cloud-norm cloud) "~A"))

(defmethod print-object ((cloud full-cloud) stream)
  (pprint-logical-block (stream ())
    (print-unreadable-object (cloud stream :type t)
      (when (slot-boundp cloud 'name)
        (format stream "~S ~:_" (ignore-errors (name cloud))))
      (format stream "~S ~:_~A" :norm (format-full-cloud-norm cloud))))
  cloud)

(defmethod initialize-instance :after ((cloud full-cloud)
                                       &key &allow-other-keys)
  (unless (slot-boundp cloud 'weights)
    (setf (slot-value cloud 'weights)
          (make-flt-array (* (size (chunk1 cloud))
                             (size (chunk2 cloud)))))
    (unless (or (conditioning-chunk-p (chunk1 cloud))
                (conditioning-chunk-p (chunk2 cloud)))
      (map-into (weights cloud)
                (lambda () (flt (* 0.01 (gaussian-random-1))))))))

(defmacro do-cloud-runs (((start end) cloud) &body body)
  "Iterate over consecutive runs of weights present in CLOUD."
  (with-gensyms (%cloud %chunk2-size %index)
    `(let ((,%cloud ,cloud))
       (if (indices-present (chunk1 ,%cloud))
           (let ((,%chunk2-size (size (chunk2 ,%cloud))))
             (do-stripes ((chunk1 ,%cloud))
               (do-chunk (,%index (chunk1 ,%cloud))
                 (let* ((,start (the! index (* ,%index ,%chunk2-size)))
                        (,end (the! index (+ ,start ,%chunk2-size))))
                   ,@body))))
           (let ((,start 0)
                 (,end (length (weights ,%cloud))))
             ,@body)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun make-do-cloud/chunk2 (chunk2-index index chunk2-size
                               offset body)
    `(do ((,chunk2-index 0 (the! index (1+ ,chunk2-index)))
          (,index ,offset (the! index (1+ ,index))))
         ((>= ,chunk2-index ,chunk2-size))
       ,@body)))

(defmacro do-cloud/chunk1 ((chunk1-index cloud) &body body)
  (with-gensyms (%cloud %chunk2-size %offset)
    `(let* ((,%cloud ,cloud)
            (,%chunk2-size (size (chunk2 ,%cloud))))
       (declare (type index ,%chunk2-size))
       (when (indices-present (chunk2 ,%cloud))
         (error "CHUNK2 cannot have INDICES-PRESENT."))
       (do-stripes ((chunk1 ,%cloud))
         (do-chunk (,chunk1-index (chunk1 ,%cloud))
           (let ((,%offset (the! index
                                 (* ,chunk1-index ,%chunk2-size))))
             (macrolet ((do-cloud/chunk2 ((chunk2-index index) &body body)
                          (make-do-cloud/chunk2 chunk2-index index
                                                ',%chunk2-size ',%offset
                                                body)))
               ,@body)))))))

(defmethod zero-weight-to-self ((cloud full-cloud))
  (when (eq (chunk1 cloud) (chunk2 cloud))
    (let ((weights (weights cloud))
          (n (size (chunk1 cloud))))
      (loop for i below n do
        (setf (aref weights (+ (* i n) i)) #.(flt 0))))))

(defmethod activate-cloud* ((cloud full-cloud) reversep
                            from-chunk to-chunk from to)
  (let ((weights (weights cloud))
        (scale1 (scale1 cloud))
        (scale2 (scale2 cloud))
        (from-size (size from-chunk))
        (to-size (size to-chunk))
        (n-stripes (n-stripes from-chunk)))
    (declare (type flt scale1 scale2)
             (type flt-vector weights from to)
             (optimize (speed 3) #.*no-array-bounds-check*))
    (if (not reversep)
        (if (use-blas-on-chunk-p (chunk1 cloud))
            (lla:gemm! scale2 from weights 1 to
                       :lda from-size :ldb to-size :ldc to-size
                       :m n-stripes :n to-size :k from-size)
            (do-cloud/chunk1 (i cloud)
              (let ((x (aref from i)))
                (unless (zerop x)
                  (setq x (* x scale2))
                  (do-cloud/chunk2 (j weight-index)
                    (incf (aref to j)
                          (* x (aref weights weight-index))))))))
        (if (use-blas-on-chunk-p (chunk1 cloud))
            (lla:gemm! scale1 from weights 1 to
                       :transpose-b? t
                       :lda from-size :ldb from-size :ldc to-size
                       :m n-stripes :n to-size :k from-size)
            (do-cloud/chunk1 (i cloud)
              (let ((sum #.(flt 0)))
                (declare (type flt sum))
                (do-cloud/chunk2 (j weight-index)
                  (incf sum (* (aref from j)
                               (aref weights weight-index))))
                (incf (aref to i) (* sum scale1)))))))
  (values))

(defgeneric accumulate-cloud-statistics* (cloud v1 v2 multiplier
                                          start accumulator))

(defmethod accumulate-cloud-statistics* ((cloud full-cloud) v1 v2 multiplier
                                         start accumulator)
  (declare (type flt multiplier)
           (type flt-vector v1 v2 accumulator)
           (type index start))
  (if (use-blas-on-chunk-p (chunk1 cloud))
      (let ((size1 (size (chunk1 cloud)))
            (size2 (size (chunk2 cloud))))
        (lla:gemm! multiplier v1 v2 (flt 1)
                    (aops:reshape accumulator (list size1 size2) start)
                    :transpose-a? t :lda size1 :ldb size2 :ldc size2
                    :m size1 :n size2 :k (n-stripes (chunk1 cloud))))
      (locally (declare (optimize (speed 3) #.*no-array-bounds-check*))
        (cond ((= multiplier (flt 1))
               (special-case (zerop start)
                 (do-cloud/chunk1 (i cloud)
                   (let ((x (aref v1 i)))
                     (unless (zerop x)
                       (do-cloud/chunk2 (j weight-index)
                         (incf (aref accumulator
                                     (the! index (+ start weight-index)))
                               (* x (aref v2 j)))))))))
              ((= multiplier (flt -1))
               (special-case (zerop start)
                 (do-cloud/chunk1 (i cloud)
                   (let ((x (aref v1 i)))
                     (unless (zerop x)
                       (do-cloud/chunk2 (j weight-index)
                         (decf (aref accumulator
                                     (the! index (+ start weight-index)))
                               (* x (aref v2 j)))))))))
              (t
               (special-case (zerop start)
                 (do-cloud/chunk1 (i cloud)
                   (let ((x (* multiplier (aref v1 i))))
                     (unless (zerop x)
                       (do-cloud/chunk2 (j weight-index)
                         (incf (aref accumulator
                                     (the! index (+ start weight-index)))
                               (* x (aref v2 j)))))))))))))

(defmethod map-segments (fn (cloud full-cloud))
  (funcall fn cloud))

(defmethod segment-weights ((cloud full-cloud))
  (values (weights cloud) 0 (array-total-size (weights cloud))))

(defmethod map-segment-runs (fn (cloud full-cloud))
  (do-cloud-runs ((start end) cloud)
    (funcall fn start end)))

(defmethod write-weights ((cloud full-cloud) stream)
  (write-double-float-array (weights cloud) stream))

(defmethod read-weights ((cloud full-cloud) stream)
  (read-double-float-array (weights cloud) stream))


;;;; Factored cloud

(defclass factored-cloud (cloud)
  ((cloud-a
    :type full-cloud :initarg :cloud-a :reader cloud-a
    :documentation "A full cloud whose visible chunk is the same as
the visible chunk of this cloud and whose hidden chunk is the same as
the visible chunk of CLOUD-B.")
   (cloud-b
    :type full-cloud :initarg :cloud-b :reader cloud-b
    :documentation "A full cloud whose hidden chunk is the same as the
hidden chunk of this cloud and whose visible chunk is the same as the
hidden chunk of CLOUD-A."))
  (:documentation "Like FULL-CLOUD but the weight matrix is factored
into a product of two matrices: A*B. At activation time, HIDDEN +=
VISIBLE*A*B."))

(define-descriptions (cloud factored-cloud :inheritp t)
  (cloud-a-norm (format-full-cloud-norm (cloud-a cloud)) "~A")
  (cloud-b-norm (format-full-cloud-norm (cloud-b cloud)) "~A"))

(defmethod print-object ((cloud factored-cloud) stream)
  (pprint-logical-block (stream ())
    (print-unreadable-object (cloud stream :type t)
      (format stream "~S ~:_(~A,~A)" :norm
              (format-full-cloud-norm (cloud-a cloud))
              (format-full-cloud-norm (cloud-b cloud)))))
  cloud)

(defclass factored-cloud-shared-chunk (chunk) ())

(defmethod copy-nodes ((chunk factored-cloud-shared-chunk))
  (nodes chunk))

(defmethod initialize-instance :after ((cloud factored-cloud) &key rank
                                       &allow-other-keys)
  (assert (typep rank '(or (integer 1) null)))
  (unless (and (slot-boundp cloud 'cloud-a)
               (slot-boundp cloud 'cloud-b))
    (let ((shared (make-instance 'factored-cloud-shared-chunk
                                 :size rank
                                 :name (list (name cloud) :shared))))
      (setf (slot-value cloud 'cloud-a)
            (make-instance 'full-cloud
                           :name (list (name cloud) :a)
                           :chunk1 (chunk1 cloud)
                           :chunk2 shared
                           :scale1 (scale1 cloud)))
      (setf (slot-value cloud 'cloud-b)
            (make-instance 'full-cloud
                           :name (list (name cloud) :b)
                           :chunk1 shared
                           :chunk2 (chunk2 cloud)
                           :scale2 (scale2 cloud))))))

(defun factored-cloud-shared-chunk (cloud)
  (chunk2 (cloud-a cloud)))

(defun rank (cloud)
  (size (factored-cloud-shared-chunk cloud)))

(defmethod set-n-stripes (n-stripes (cloud factored-cloud))
  (setf (n-stripes (factored-cloud-shared-chunk cloud)) n-stripes))

(defmethod set-max-n-stripes (max-n-stripes (cloud factored-cloud))
  (setf (max-n-stripes (factored-cloud-shared-chunk cloud)) max-n-stripes))

(defmethod zero-weight-to-self ((cloud factored-cloud))
  (when (eq (chunk1 cloud) (chunk2 cloud))
    (error "ZERO-WEIGHT-TO-SELF not implemented for FACTORED-CLOUD")))

(defmethod activate-cloud* ((cloud factored-cloud) reversep from-chunk to-chunk
                            from to)
  (let ((shared (factored-cloud-shared-chunk cloud))
        (nodes (nodes (factored-cloud-shared-chunk cloud))))
    ;; Normal chunks are zeroed by HIJACK-MEANS-TO-ACTIVATION.
    (zero-chunk shared)
    (cond ((not reversep)
           (activate-cloud* (cloud-a cloud) reversep
                            from-chunk shared from nodes)
           (activate-cloud* (cloud-b cloud) reversep
                            shared to-chunk nodes to))
          (t
           (activate-cloud* (cloud-b cloud) reversep
                            from-chunk shared from nodes)
           (activate-cloud* (cloud-a cloud) reversep
                            shared to-chunk nodes to)))))

(defmethod map-segments (fn (cloud factored-cloud))
  (funcall fn (cloud-a cloud))
  (funcall fn (cloud-b cloud)))

(defmethod write-weights ((cloud factored-cloud) stream)
  (write-weights (cloud-a cloud) stream)
  (write-weights (cloud-b cloud) stream))

(defmethod read-weights ((cloud factored-cloud) stream)
  (read-weights (cloud-a cloud) stream)
  (read-weights (cloud-b cloud) stream))


;;;; Boltzmann Machine

(defclass bm ()
  ((chunks
    :type list :reader chunks
    :documentation "A list of all the chunks in this BM. It's
VISIBLE-CHUNKS and HIDDEN-CHUNKS appended.")
   (visible-chunks
    :type list :initarg :visible-chunks :reader visible-chunks
    :documentation "A list of CHUNKs whose values come from the
outside world: SET-INPUT sets them.")
   (hidden-chunks
    :type list :initarg :hidden-chunks :reader hidden-chunks
    :documentation "A list of CHUNKs that are not directly observed.
Disjunct from VISIBLE-CHUNKS.")
   (visible-and-conditioning-chunks
    :type list :reader visible-and-conditioning-chunks)
   (hidden-and-conditioning-chunks
    :type list :reader hidden-and-conditioning-chunks)
   (conditioning-chunks :type list :reader conditioning-chunks)
   (clouds
    :type list :initform '(:merge) :initarg :clouds :reader clouds
    :documentation "Normally, a list of CLOUDS representing the
connections between chunks. During initialization cloud specs are
allowed in the list.")
   (has-hidden-to-hidden-p :reader has-hidden-to-hidden-p)
   (has-visible-to-visible-p :reader has-visible-to-visible-p)
   (max-n-stripes :initform 1 :initarg :max-n-stripes :reader max-n-stripes))
  (:documentation "The network is assembled from CHUNKS (nodes of the
same behaviour) and CLOUDs (connections between two chunks). To
instantiate, arrange for VISIBLE-CHUNKS, HIDDEN-CHUNKS, CLOUDS (either
as initargs or initforms) to be set.

Usage of CLOUDS is slightly tricky: you may pass a list of CLOUD
objects connected to chunks in this network. Alternatively, a cloud
spec may stand for a cloud. Also, the initial value of CLOUDS is
merged with the default cloud spec list before the final cloud spec
list is instantiated. The default cloud spec list is what
FULL-CLOUDS-EVERYWHERE returns for VISIBLE-CHUNKS and HIDDEN-CHUNKS.
See MERGE-CLOUD-SPECS for the gory details. The initform, '(:MERGE),
simply leaves the default cloud specs alone."))

(defmethod print-object ((bm bm) stream)
  (pprint-logical-block (stream ())
    (print-unreadable-object (bm stream :type t)
      (format stream "~S - ~S"
              (mapcar (lambda (chunk)
                        (ignore-errors (name chunk)))
                      (visible-chunks bm))
              (mapcar (lambda (chunk)
                        (ignore-errors (name chunk)))
                      (hidden-chunks bm)))))
  bm)

(define-descriptions (bm bm)
  visible-chunks hidden-chunks clouds n-stripes max-n-stripes)

(defgeneric find-chunk (name object &key errorp)
  (:documentation "Find the chunk in OBJECT whose name is EQUAL to
NAME. Signal an error if not found and ERRORP.")
  (:method (name (bm bm) &key errorp)
    (or (find name (chunks bm) :key #'name :test #'name=)
        (if errorp
            (error "Cannot find chunk ~S." name)
            nil))))

(defmethod find-striped (name (bm bm))
  (find-chunk name bm))

(defmacro do-clouds ((cloud bm) &body body)
  `(dolist (,cloud (clouds ,bm))
     ,@body))

(defmethod n-stripes ((bm bm))
  (n-stripes (first (visible-chunks bm))))

(defmethod set-n-stripes (n-stripes (bm bm))
  (dolist (chunk (chunks bm))
    (setf (n-stripes chunk) n-stripes))
  (do-clouds (cloud bm)
    (setf (n-stripes cloud) n-stripes)))

(defmethod set-max-n-stripes (max-n-stripes (bm bm))
  (setf (slot-value bm 'max-n-stripes) max-n-stripes)
  (dolist (chunk (chunks bm))
    (setf (max-n-stripes chunk) max-n-stripes))
  (do-clouds (cloud bm)
    (setf (max-n-stripes cloud) max-n-stripes)))

(defgeneric find-cloud (name object &key errorp)
  (:documentation "Find the cloud in OBJECT whose name is EQUAL to
NAME. Signal an error if not found and ERRORP.")
  (:method (name (bm bm) &key errorp)
    (or (find name (clouds bm) :key #'name :test #'equal)
        (if errorp
            (error "Cannot find cloud ~S." name)
            nil))))

(defun ->cloud (cloud-designator bm)
  (if (typep cloud-designator 'cloud)
      cloud-designator
      (find-cloud cloud-designator bm :errorp t)))

(defun ->clouds (chunks cloud-specs)
  (flet ((name* (chunk-or-name)
           (if (typep chunk-or-name 'chunk)
               (name chunk-or-name)
               chunk-or-name)))
    (let ((clouds
           (loop for spec in cloud-specs
                 collect
                 (if (typep spec 'cloud)
                     spec
                     (multiple-value-bind (known unknown)
                         (split-plist spec '(:class :name :chunk1 :chunk2))
                       (destructuring-bind (&key (class 'full-cloud)
                                                 chunk1 chunk2
                                                 (name
                                                  (list (name* chunk1)
                                                        (name* chunk2))))
                           known
                         (apply #'make-instance
                                class
                                :name name
                                :chunk1 (->chunk chunk1 chunks)
                                :chunk2 (->chunk chunk2 chunks)
                                unknown)))))))
      (when (name-clashes clouds)
        (error "Name conflict among clouds: ~S." (name-clashes clouds)))
      clouds)))

(defun name-clashes (list)
  (let ((names (mapcar #'name list)))
    (set-difference names
                    (remove-duplicates names :test #'equal)
                    :test #'equal)))

(defun full-clouds-everywhere (visible-chunks hidden-chunks)
  "Return a list of cloud specifications suitable for instantiating a
BM. Put a cloud between each pair of visible and hidden chunks unless
they are both conditioning chunks. The names of the clouds are two
element lists of the names of the visible and hidden chunks."
  (let ((clouds '()))
    (dolist (visible-chunk visible-chunks)
      (dolist (hidden-chunk hidden-chunks)
        (unless (and (conditioning-chunk-p visible-chunk)
                     (conditioning-chunk-p hidden-chunk))
          (push `(:chunk1 ,(name visible-chunk)
                  :chunk2 ,(name hidden-chunk))
                clouds))))
    (nreverse clouds)))

(defun merge-cloud-specs (specs default-specs)
  "Combine cloud SPECS and DEFAULT-SPECS. If the first element of
SPECS is :MERGE then merge them else return SPECS. Merging
concatenates them but removes those specs from DEFAULT-SPECS that are
between chunks that have a spec in SPECS. If a spec has CLASS NIL then
it is removed as well. A cloud spec at minimum specifies the name of
the chunks it connects:

  (:chunk1 inputs :chunk2 features)

in which case it defaults to be a FULL-CLOUD. If that is not desired
then the class can be specified:

  (:chunk1 inputs :chunk2 features :class factored-cloud)

To remove a cloud from DEFAULT-SPECS use :CLASS NIL:

  (:chunk1 inputs :chunk2 features :class nil)

Other initargs are passed as is to MAKE-INSTANCE:

  (:chunk1 inputs :chunk2 features :class factored-cloud :rank 10)

You may also pass a CLOUD object as a spec."
  (labels ((getf* (plist indicator)
             (let* ((secret (gensym))
                    (name (getf plist indicator secret)))
               (if (eq name secret)
                   (error "No ~S found in ~S." indicator plist)
                   name)))
           (chunk1-name (spec)
             (if (listp spec)
                 (getf* spec :chunk1)
                 (name (chunk1 spec))))
           (chunk2-name (spec)
             (if (listp spec)
                 (getf* spec :chunk2)
                 (name (chunk2 spec))))
           (match (spec1 spec2)
             (and (equal (chunk1-name spec1)
                         (chunk1-name spec2))
                  (equal (chunk2-name spec1)
                         (chunk2-name spec2)))))
    (if (eq :merge (first specs))
        (let ((specs (rest specs)))
          (remove-if (lambda (spec)
                       (and (not (typep spec 'cloud))
                            (null (getf spec :class 'full-cloud))))
                     (append (remove-if (lambda (spec)
                                          (some (lambda (spec1)
                                                  (match spec spec1))
                                                specs))
                                        default-specs)
                             specs)))
        specs)))

(defmethod initialize-instance :after ((bm bm) &key &allow-other-keys)
  "Return an BM that consists of VISIBLE-CHUNKS, HIDDEN-CHUNKS and
CLOUDS of weights where CLOUDS is a list of cloud specifications.
Names of chunks and clouds must be unique under EQUAL. CLOUDS is
merged with DEFAULT-CLOUDS. DEFAULT-CLOUDS defaults to connecting all
visible and hidden chunks with FULL-CLOUDS without any intralayer
connection. See MERGE-CLOUD-SPECS on the semantics of merging."
  (let* ((visible-chunks (visible-chunks bm))
         (hidden-chunks (hidden-chunks bm)))
    (setf (slot-value bm 'chunks) (append visible-chunks hidden-chunks))
    (let ((name-clashes (name-clashes (chunks bm))))
      (when name-clashes
        (error "Name conflict among chunks ~S." name-clashes)))
    (unless (every (lambda (obj) (typep obj 'cloud)) (clouds bm))
      (setf (slot-value bm 'clouds)
            (->clouds (chunks bm)
                      (merge-cloud-specs (clouds bm)
                                         (full-clouds-everywhere
                                          visible-chunks
                                          hidden-chunks)))))
    ;; make sure chunks have the same MAX-N-STRIPES
    (setf (max-n-stripes bm) (max-n-stripes bm))
    (setf (slot-value bm 'visible-and-conditioning-chunks)
          (append visible-chunks
                  (remove-if-not #'conditioning-chunk-p hidden-chunks)))
    (setf (slot-value bm 'hidden-and-conditioning-chunks)
          (append hidden-chunks
                  (remove-if-not #'conditioning-chunk-p visible-chunks)))
    (setf (slot-value bm 'conditioning-chunks)
          (append (remove-if-not #'conditioning-chunk-p visible-chunks)
                  (remove-if-not #'conditioning-chunk-p hidden-chunks)))
    (setf (slot-value bm 'has-visible-to-visible-p)
          (not (not
                (some (lambda (cloud)
                        (both-cloud-ends-in-p cloud
                                              (remove-if #'conditioning-chunk-p
                                                         visible-chunks)))
                      (clouds bm)))))
    (setf (slot-value bm 'has-hidden-to-hidden-p)
          (not (not
                (some (lambda (cloud)
                        (both-cloud-ends-in-p cloud
                                              (remove-if #'conditioning-chunk-p
                                                         hidden-chunks)))
                      (clouds bm)))))))

(defun swap-nodes (chunks)
  (dolist (chunk chunks)
    (rotatef (slot-value chunk 'nodes)
             (slot-value chunk 'old-nodes))))

(defun set-mean (chunks bm
                 &key (other-chunks (set-difference (chunks bm) chunks)))
  (swap-nodes (chunks bm))
  (hijack-means-to-activation chunks (clouds bm))
  (map nil #'set-chunk-mean chunks)
  ;; These did not change. Simply swap them back.
  (swap-nodes other-chunks))

(defun swap-nodes* (chunks)
  (dolist (chunk chunks)
    (rotatef (slot-value chunk 'old-nodes)
             (slot-value chunk 'means))))

;;; This is broken if there are connections among CHUNKS.
(defun set-mean* (chunks bm
                  &key (other-chunks (set-difference (chunks bm) chunks)))
  (swap-nodes* (chunks bm))
  (hijack-means-to-activation chunks (clouds bm))
  (map nil #'set-chunk-mean chunks)
  ;; These did not change. Simply swap them back.
  (swap-nodes* other-chunks))

(defun set-visible-mean/1 (bm)
  "Set NODES of the chunks in the visible layer to the means of their
respective probability distributions."
  (set-mean (visible-chunks bm) bm :other-chunks (hidden-chunks bm)))

(defun set-hidden-mean/1 (bm)
  "Set NODES of the chunks in the hidden layer to the means of their
respective probability distributions."
  (set-mean (hidden-chunks bm) bm :other-chunks (visible-chunks bm))
  (dolist (chunk (visible-chunks bm))
    (when (typep chunk 'temporal-chunk)
      (maybe-remember chunk))))

(defun sample-visible (bm)
  "Generate samples from the probability distribution defined by the
chunk type and the mean that resides in NODES."
  (map nil #'sample-chunk (visible-chunks bm)))

(defun sample-hidden (bm)
  "Generate samples from the probability distribution defined by the
chunk type and the mean that resides in NODES."
  (map nil #'sample-chunk (hidden-chunks bm)))

(defmethod set-input :before (samples (bm bm))
  (setf (n-stripes bm) (length samples))
  (dolist (chunk (visible-chunks bm))
    (when (typep chunk 'temporal-chunk)
      (maybe-use-remembered chunk))))

(defmethod set-input :after (samples (bm bm))
  (nodes->inputs bm)
  (visible-nodes->means bm))

(defmethod map-segments (fn (bm bm))
  (map nil (lambda (cloud)
             (map-segments fn cloud))
       (clouds bm)))

(defmethod write-weights ((bm bm) stream)
  (dolist (cloud (clouds bm))
    (write-weights cloud stream)))

(defmethod read-weights ((bm bm) stream)
  (dolist (cloud (clouds bm))
    (read-weights cloud stream)))


;;;; Deep Boltzmann Machine

(defclass dbm (bm)
  ((layers
    :initarg :layers :type list :reader layers
    :documentation "A list of layers from bottom up. A layer is a list
of chunks. The layers partition the set of all chunks in the BM.
Chunks with no connections to layers below are visible (including
constant and conditioning) chunks. The layered structure is used in
the single, bottom-up, approximate inference pass. When instantiating
a DBM, VISIBLE-CHUNKS and HIDDEN-CHUNKS are inferred from LAYERS and
CLOUDS.")
   (clouds-up-to-layers
    :type list :reader clouds-up-to-layers
    :documentation "Each element of this list is a list of clouds
connected from below to the layer of the same index."))
  (:documentation "A Deep Boltzmann Machine. See \"Deep Boltzmann
Machines\" by Ruslan Salakhutdinov and Geoffrey Hinton at
<http://www.cs.toronto.edu/~hinton/absps/dbm.pdf>.

To instantiate, set up LAYERS and CLOUDS but not VISIBLE-CHUNKS and
HIDDEN-CHUNKS, because contrary to how initialization works in the
superclass (BM), the values of these slots are inferred from LAYERS
and CLOUDS: chunks without a connection from below are visible while
the rest are hidden.

The default cloud spec list is computed by calling
FULL-CLOUDS-EVERYWHERE-BETWEEN-LAYERS on LAYERS."))

(defun full-clouds-everywhere-between-layers (layers)
  (loop for (layer1 layer2) on layers
        while layer2
        append (full-clouds-everywhere layer1 layer2)))

;;; See if CHUNK has a cloud among CLOUDS that connects it to any of
;;; CHUNKS.
(defun connects-to-p (chunk chunks clouds)
  (some (lambda (cloud)
          (if (typep cloud 'cloud)
              (or (and (eq chunk (chunk1 cloud))
                       (member (chunk2 cloud) chunks))
                  (and (eq chunk (chunk2 cloud))
                       (member (chunk1 cloud) chunks)))
              ;; Same thing for cloud specs.
              (let ((chunk1-name (getf cloud :chunk1))
                    (chunk2-name (getf cloud :chunk2))
                    (chunk-name (name chunk)))
                (or (and (eq chunk-name chunk1-name)
                         (member chunk2-name chunks
                                 :key #'name :test #'equal))
                    (and (eq chunk-name chunk2-name)
                         (member chunk1-name chunks
                                 :key #'name :test #'equal))))))
        clouds))

(defmethod initialize-instance :around ((dbm dbm) &rest initargs
                                        &key &allow-other-keys)
  ;; We need LAYERS and CLOUDS in order to infer visible/hidden
  ;; chunks, so compute clouds here.
  ;;
  ;; LAYERS might have an initform in a subclass or be passed as an
  ;; initarg. Call SHARED-INITIALIZE for the slots we are interested
  ;; in, so that they are initialized to whatever value takes
  ;; precedence.
  (apply #'shared-initialize dbm '(layers clouds visible-chunks hidden-chunks)
         initargs)
  (when (or (slot-boundp dbm 'visible-chunks)
            (slot-boundp dbm 'hidden-chunks))
    (error "Don't supply VISIBLE-CHUNKS and HIDDEN-CHUNKS for DBMs."))
  (let ((clouds (clouds dbm))
        (layers (layers dbm))
        (visible-chunks ())
        (hidden-chunks ()))
    ;; Merge clouds, at this point it may contain cloud specs or cloud
    ;; objects. Specs will be resolved in due time by the next method.
    (setq clouds
          (merge-cloud-specs clouds
                             (full-clouds-everywhere-between-layers layers)))
    ;; Infer VISIBLE-CHUNKS, HIDDEN-CHUNKS from LAYERS and CLOUDS.
    (dolist (layer (layers dbm))
      (let ((layer-visible-chunks ())
            (layer-hidden-chunks ()))
        (dolist (chunk layer)
          (if (or (connects-to-p chunk visible-chunks clouds)
                  (connects-to-p chunk hidden-chunks clouds))
              (push chunk layer-hidden-chunks)
              (push chunk layer-visible-chunks)))
        (setq visible-chunks (append visible-chunks
                                     (reverse layer-visible-chunks)))
        (setq hidden-chunks (append hidden-chunks
                                    (reverse layer-hidden-chunks)))))
    (apply #'call-next-method dbm
           :clouds clouds
           :visible-chunks visible-chunks
           :hidden-chunks hidden-chunks
           initargs)))

;;; Check that there are no clouds between non-adjacent layers. FIXME:
;;; should intralayer connections be allowed?
(defun check-dbm-clouds (dbm)
  (let ((bad-clouds
          (set-difference (clouds dbm)
                          (apply #'append (clouds-up-to-layers dbm)))))
    (when bad-clouds
      (error "In ~A some clouds are between non-adjecent layers: ~A"
             dbm bad-clouds))))

(defmethod initialize-instance :after ((dbm dbm) &key &allow-other-keys)
  (setf (slot-value dbm 'clouds-up-to-layers)
        (loop for layer-below = () then layer
              for layer in (layers dbm)
              collect (remove-if-not
                       (lambda (cloud)
                         (cloud-between-chunks-p cloud layer-below layer))
                       (clouds dbm))))
  (check-dbm-clouds dbm))

(defun conditioning-clouds-to (chunks clouds)
  (remove-if-not (lambda (cloud)
                   (and (conditioning-cloud-p cloud)
                        (or (member (chunk1 cloud) chunks)
                            (member (chunk2 cloud) chunks))))
                 clouds))

(defun up-dbm (dbm)
  "Do a single upward pass in DBM, performing approximate inference.
Disregard intralayer and downward connections, double activations to
chunks having upward connections."
  (loop for (layer-below layer layer-above) on (layers dbm)
        for (clouds-up-to-layer clouds-up-to-layer-above)
          on (rest (clouds-up-to-layers dbm))
        while layer
        do (swap-nodes layer-below)
           (let* ((layer*
                    (set-difference layer
                                    (visible-and-conditioning-chunks dbm)))
                  (layer-above*
                    (set-difference layer-above
                                    (visible-and-conditioning-chunks dbm))))
             (hijack-means-to-activation layer* clouds-up-to-layer)
             ;; Double activations of chunks in LAYER that have non-bias
             ;; connections to LAYER-ABOVE.
             (dolist (chunk layer*)
               (when (connects-to-p chunk layer-above* clouds-up-to-layer-above)
                 (lla:scal! #.(flt 2) (nodes chunk))))
             (map nil #'set-chunk-mean layer*)
             (swap-nodes layer-below))))

(defun down-dbm (dbm)
  "Do a single downward pass in DBM, propagating the mean-field much
like performing approximate inference, but in the other direction.
Disregard intralayer and upward connections, double activations to
chunks having downward connections."
  (loop for (layer-above layer layer-below) on (reverse (layers dbm))
        for (clouds-down-to-layer clouds-down-to-layer-below)
          on (reverse (clouds-up-to-layers dbm))
        while layer
        do (swap-nodes layer-above)
           (hijack-means-to-activation layer clouds-down-to-layer)
           ;; Double activations of chunks in LAYER that have connections
           ;; to LAYER-BELOW.
           (dolist (chunk layer)
             (when (and (not (conditioning-chunk-p chunk))
                        (connects-to-p chunk layer-below
                                       clouds-down-to-layer-below))
               (lla:scal! #.(flt 2) (nodes chunk))))
           (map nil #'set-chunk-mean layer)
           (swap-nodes layer-above)))


;;;; DBM->DBN

(define-slots-not-to-be-copied 'dbm->dbn chunk
  nodes means old-nodes inputs indices-present)

(defmethod copy-object-extra-initargs ((context (eql 'dbm->dbn)) (chunk chunk))
  `(:size ,(size chunk)
    :max-n-stripes ,(max-n-stripes chunk)))

(define-slots-not-to-be-copied 'dbm->dbn temporal-chunk
  next-node-inputs has-inputs-p)

(define-slots-not-to-be-copied 'dbm->dbn cloud
  cached-version1 cached-version2
  cached-activations1 cached-activations2)

(define-slots-to-be-shallow-copied 'dbm->dbn full-cloud
  weights)

(define-slots-not-to-be-copied 'dbm->dbn bm
  chunks max-n-stripes)

(defun copy-dbm-chunk-to-dbn (chunk)
  (copy 'dbm->dbn chunk))

;;; C1 <-W-> C2: C1 * W -> C2, C1 <- W^T * C2
;;;
;;; C1 <-W-> C2 <-> C3: C1 * W * 2 -> C2, C1 <- W^T * C2
;;;
;;; C0 <-> C1 <-W-> C2: C1 * W -> C2, C1 <- 2 * W^T * C2
;;;
;;; C0 <-> C1 <-W-> C2 <-> C3: C1 * W * 2 -> C2, C1 <- 2 * W^T * C2
;;;
;;; In short, double activation from the cloud if the target chunk has
;;; input from another layer.
(defun copy-dbm-cloud-to-dbn (cloud clouds
                              layer-below layer1 layer2 layer-above)
  (let ((chunk1 (chunk1 cloud))
        (chunk2 (chunk2 cloud))
        (copy (copy 'dbm->dbn cloud)))
    (when (and (member chunk1 layer1)
               (connects-to-p chunk1 layer-below clouds))
      (setf (slot-value copy 'scale1) (flt 2)))
    (when (and (member chunk2 layer2)
               (connects-to-p chunk2 layer-above clouds))
      (setf (slot-value copy 'scale2) (flt 2)))
    (when (and (member chunk2 layer1)
               (connects-to-p chunk2 layer-below clouds))
      (setf (slot-value copy 'scale2) (flt 2)))
    (when (and (member chunk1 layer2)
               (connects-to-p chunk1 layer-above clouds))
      (setf (slot-value copy 'scale1) (flt 2)))
    copy))

(defun stable-set-difference (list1 list2)
  (remove-if (lambda (x)
               (member x list2))
             list1))

(defun dbm->dbn (dbm &key (rbm-class 'rbm) (dbn-class 'dbn)
                 dbn-initargs)
  "Convert DBM to a DBN by discarding intralayer connections and
doubling activations of clouds where necessary. If a chunk does not
have input from below then scale its input from above by 2; similarly,
if a chunk does not have input from above then scale its input from
below by 2. By default, weights are shared between clouds and their
copies.

For now, unrolling the resulting DBN to a BPN is not supported."
  (let* ((clouds (clouds dbm))
         (rbms (with-copying
                 (loop
                  for layer-below = nil then layer1
                  for (layer1 layer2 layer-above) on (layers dbm)
                  while layer2
                  collect
                  (flet ((copy-cloud (cloud)
                           (copy-dbm-cloud-to-dbn cloud clouds
                                                  layer-below
                                                  layer1 layer2
                                                  layer-above))
                         (cloud-between-layers-p (cloud)
                           (cloud-between-chunks-p
                            cloud layer1 layer2)))
                    (make-instance rbm-class
                                   :visible-chunks (mapcar
                                                    #'copy-dbm-chunk-to-dbn
                                                    layer1)
                                   :hidden-chunks (mapcar
                                                   #'copy-dbm-chunk-to-dbn
                                                   (stable-set-difference
                                                    layer2
                                                    (visible-chunks dbm)))
                                   :clouds (mapcar #'copy-cloud
                                                   (remove-if-not
                                                    #'cloud-between-layers-p
                                                    clouds))))))))
    (apply #'make-instance dbn-class
           :rbms rbms
           dbn-initargs)))


;;;; Restricted Boltzmann Machine

(defclass rbm (bm)
  ((dbn :initform nil :type (or null dbn) :reader dbn))
  (:documentation "An RBM is a BM with no intralayer connections. An
RBM when trained with PCD behaves the same as a BM with the same
chunks, clouds but it can also be trained by contrastive
divergence (see RBM-CD-TRAINER) and stacked in a DBN."))

(define-descriptions (rbm rbm :inheritp t)
  dbn)

(defmethod initialize-instance :after ((rbm rbm) &key &allow-other-keys)
  (when (has-visible-to-visible-p rbm)
    (error "An RBM cannot have visible to visible connections."))
  (when (has-hidden-to-hidden-p rbm)
    (error "An RBM cannot have hidden to hidden connections.")))


;;;; Mean field

(defun node-change (chunks)
  "Return the average of the absolute values of NODES - OLD-NODES over
CHUNKS. The second value returned is the number of nodes that
contributed to the average."
  (let ((sum #.(flt 0))
        (n 0))
    (declare (type flt sum) (type index n) (optimize (speed 3)))
    (dolist (chunk chunks)
      (unless (conditioning-chunk-p chunk)
        (let ((nodes (nodes* chunk))
              (old-nodes (the flt-vector (old-nodes chunk))))
          (do-stripes (chunk)
            (do-chunk (i chunk)
              (let ((x (aref nodes i))
                    (y (aref old-nodes i)))
                (incf sum (abs (- x y)))
                (incf n)))))))
    (values (/ sum n) n)))

(defun supervise-mean-field/default (chunks bm iteration &key
                                     (node-change-limit #.(flt 0.0000001))
                                     (n-undamped-iterations 100)
                                     (n-damped-iterations 100)
                                     (damping-factor #.(flt 0.9)))
  "A supervisor for SETTLE-MEAN-FIELD. Return NIL if the average of
the absolute value of change in nodes is below NODE-CHANGE-LIMIT, else
return 0 damping for N-UNDAMPED-ITERATIONS then DAMPING-FACTOR for
another N-DAMPED-ITERATIONS, then NIL."
  (declare (ignore bm))
  (let ((change (node-change chunks)))
    (cond ((< change node-change-limit)
           nil)
          ((< iteration n-undamped-iterations)
           #.(flt 0))
          ((< iteration (+ n-undamped-iterations n-damped-iterations))
           damping-factor)
          (t
           nil))))

(defgeneric default-mean-field-supervisor (bm)
  (:documentation "Return a function suitable as the SUPERVISOR
argument for SETTLE-MEAN-FIELD. The default implementation ")
  (:method ((bm bm))
    #'supervise-mean-field/default))

(defun settle-mean-field (chunks bm &key
                          (other-chunks (set-difference (chunks bm) chunks))
                          (supervisor (default-mean-field-supervisor bm)))
  "Do possibly damped mean field updates on CHUNKS until convergence.
Compute V'_{t+1}, what would normally be the means, but average it
with the previous value: V_{t+1} = k * V_t + (1 - k) * V'{t+1} where K
is the damping factor (an FLT between 0 and 1).

Call SUPERVISOR with CHUNKS BM and the iteration. Settling is finished
when SUPERVISOR returns NIL. If SUPERVISOR returns a non-nil value
then it's taken to be a damping factor. For no damping return 0."
  (declare (ignore other-chunks))
  (loop for i upfrom 0 do
        (dolist (chunk chunks)
          (set-mean (list chunk) bm))
        (let ((damping-factor (funcall supervisor chunks bm i)))
          (unless damping-factor
            (return))
          (unless (= #.(flt 0) damping-factor)
            (sum-nodes-and-old-nodes chunks
                                     (flt (- 1 damping-factor))
                                     (flt damping-factor)))))
  (map nil #'nodes->means chunks))

(defun settle-visible-mean-field
    (bm &key (supervisor (default-mean-field-supervisor bm)))
  "Convenience function on top of SETTLE-MEAN-FIELD."
  (when (has-visible-to-visible-p bm)
    (settle-mean-field (visible-chunks bm) bm :other-chunks (hidden-chunks bm)
                       :supervisor supervisor)))

(defun settle-hidden-mean-field
    (bm &key (supervisor (default-mean-field-supervisor bm)))
  "Convenience function on top of SETTLE-MEAN-FIELD."
  (when (has-hidden-to-hidden-p bm)
    (settle-mean-field (hidden-chunks bm) bm :other-chunks (visible-chunks bm)
                       :supervisor supervisor)))

(defgeneric set-visible-mean (bm)
  (:documentation "Like SET-VISIBLE-MEAN/1, but settle the mean field
if there are visible-to-visible connections. For an RBM it trivially
calls SET-VISIBLE-MEAN.")
  (:method :around ((bm bm))
           (with-versions ((gensym) (hidden-and-conditioning-chunks bm))
             (call-next-method)))
  (:method ((bm bm))
    ;; It could be initialized randomly. Instead, we just leave the
    ;; values alone. Also, SETTLE-VISIBLE-MEAN-FIELD does not do
    ;; anything when there are no visible-to-visible connections, so
    ;; this is fine for an RBM.
    (set-visible-mean/1 bm)
    (settle-visible-mean-field bm)))

(defgeneric set-hidden-mean (bm)
  (:documentation "Like SET-HIDDEN-MEAN/1, but settle the mean field
if there are hidden-to-hidden connections. For an RBM it trivially
calls SET-HIDDEN-MEAN/1, for a DBM it calls UP-DBM before settling.")
  (:method :around ((bm bm))
           (with-versions ((gensym) (visible-and-conditioning-chunks bm))
             (call-next-method)))
  (:method ((bm bm))
    ;; It could be initialized randomly. Instead, we just leave the
    ;; values alone. Also, SETTLE-HIDDEN-MEAN-FIELD does not do
    ;; anything when there are no hidden-to-hidden connections, so
    ;; this is fine for an RBM.
    (set-hidden-mean/1 bm)
    (settle-hidden-mean-field bm))
  (:method ((dbm dbm))
    (up-dbm dbm)
    (settle-hidden-mean-field dbm)))


;;;; Integration with gradient descent

;;; Base class for BM trainers with a positive and negative phase (CD
;;; and PCD).
(defclass segmented-gd-bm-trainer (segmented-gd-trainer) ())

;;; Return the node vector for calculating cloud statistics.
(defun means-or-samples (trainer bm chunk)
  (if (member chunk (visible-chunks bm))
      (if (eq t (visible-sampling trainer))
          (nodes chunk)
          (means chunk))
      (if (eq t (hidden-sampling trainer))
          (nodes chunk)
          (means chunk))))

(defmethod accumulate-cloud-statistics ((trainer segmented-gd-bm-trainer)
                                        (bm bm) (cloud full-cloud) multiplier)
  (declare (type flt multiplier))
  (with-segment-gradient-accumulator ((start accumulator)
                                      (cloud trainer))
    (when (and accumulator start)
      (let ((v1 (means-or-samples trainer bm (chunk1 cloud)))
            (v2 (means-or-samples trainer bm (chunk2 cloud))))
        (accumulate-cloud-statistics* cloud v1 v2 multiplier
                                      start accumulator)))))

(defmethod accumulate-cloud-statistics ((trainer segmented-gd-bm-trainer)
                                        (bm bm) (cloud factored-cloud)
                                        multiplier)
  (declare (type flt multiplier))
  (let* ((chunk1 (chunk1 cloud))
         (chunk2 (chunk2 cloud))
         (size1 (size chunk1))
         (size2 (size chunk2))
         (v (means-or-samples trainer bm chunk1))
         (h (means-or-samples trainer bm chunk2))
         (a (weights (cloud-a cloud)))
         (b (weights (cloud-b cloud)))
         (n-stripes (n-stripes (chunk1 cloud)))
         (shared (factored-cloud-shared-chunk cloud))
         (x (nodes shared))
         (n-shared (size shared)))
    (check-stripes chunk1)
    (when (indices-present chunk1)
      (error "Missing value support not implemented for FACTORED-CLOUD."))
    (assert (null (indices-present chunk2)))
    (with-segment-gradient-accumulator ((start accumulator)
                                        ((cloud-a cloud) trainer))
      (when (and accumulator start)
        ;; dCD/dA = v'*h*B'
        (lla:gemm! (flt 1) h b (flt 0) x
                   :transpose-b? t
                   :lda size2 :ldb size2 :ldc n-shared
                   :m n-stripes :n n-shared :k size2)
        (lla:gemm! multiplier v x (flt 1)
                   (aops:displace accumulator (array-total-size a) start)
                   :transpose-a? t
                   :lda size1 :ldb n-shared :ldc n-shared
                   :m size1 :n n-shared :k n-stripes)))
    (with-segment-gradient-accumulator ((start accumulator)
                                        ((cloud-b cloud) trainer))
      (when (and accumulator start)
        ;; dCD/dB = A'*v'*h
        (lla:gemm! (flt 1) a v (flt 0) x
                   :transpose-a? t :transpose-b? t
                   :lda n-shared :ldb size1 :ldc n-stripes
                   :m n-shared :n n-stripes :k size1)
        (lla:gemm! multiplier x h (flt 1)
                   (aops:displace accumulator (array-total-size b) start)
                   :lda n-stripes :ldb size2 :ldc size2
                   :m n-shared :n size2 :k n-stripes)))))

(defgeneric accumulate-positive-phase-statistics (trainer bm &key multiplier)
  (:method ((trainer segmented-gd-bm-trainer) bm &key (multiplier (flt 1)))
    (do-clouds (cloud bm)
      (accumulate-cloud-statistics trainer bm cloud (flt (* -1 multiplier))))))

(defgeneric accumulate-negative-phase-statistics (trainer bm &key multiplier)
  (:method ((trainer segmented-gd-bm-trainer) bm &key (multiplier (flt 1)))
    (do-clouds (cloud bm)
      (accumulate-cloud-statistics trainer bm cloud (flt multiplier)))))

(defmethod train (sampler (trainer segmented-gd-bm-trainer) (bm bm))
  (while (not (finishedp sampler))
    (train-batch (sample-batch sampler
                               (or (n-inputs-until-update trainer)
                                   (max-n-stripes bm)))
                 trainer bm)))

(defgeneric positive-phase (batch trainer bm))

(defgeneric negative-phase (batch trainer bm))


;;;; Sparseness
;;;;
;;;; It could be implemented by remembering average means per chunk.
;;;; However, that would run into trouble with SEGMENTED-GD-TRAINER
;;;; having children with different batch sizes as they would require
;;;; that the average be over different time periods. Thus, the
;;;; average means must reside in the child trainer, at the cost of
;;;; minor loss of performance.

(defclass sparsity-gradient-source ()
  ((cloud :type cloud :initarg :cloud :reader cloud)
   (chunk :type chunk :initarg :chunk :reader chunk)
   (sparsity-target
    :type flt
    :initarg :sparsity :initarg :target :initarg :sparsity-target
    :reader sparsity-target :reader target)
   (cost :type flt :initarg :cost :reader cost)
   (damping :type flt :initarg :damping :reader damping)))

(defmethod print-object ((sparsity sparsity-gradient-source) stream)
  (pprint-logical-block (stream ())
    (print-unreadable-object (sparsity stream :type t :identity t)
      (format stream "~S ~:_~S"
              (ignore-errors (name (cloud sparsity)))
              (ignore-errors (name (chunk sparsity))))))
  sparsity)

(define-descriptions (sparsity sparsity-gradient-source)
  cloud chunk
  (target (target sparsity) "~,5E")
  (cost (cost sparsity) "~,5E")
  (damping (damping sparsity) "~,5E"))

(defclass normal-sparsity-gradient-source (sparsity-gradient-source)
  ((products :type flt-vector :initarg :products :reader products)
   (old-products :type flt-vector :initarg :old-products :reader old-products))
  (:documentation "Keep track of how much pairs of nodes connected by
CLOUD are simultaneously active. If a node in CHUNK deviates from the
target sparsity, that is, its average activation is different from the
target, then decrease or increase the weight to nodes to which it's
connected by CLOUD in such a way that it will be closer to the target.
Smooth the empirical estimates in simultaneous activations in PRODUCTS
by DAMPING."))

(defclass cheating-sparsity-gradient-source (sparsity-gradient-source)
  ((sum1 :type flt-vector :initarg :sum1 :reader sum1)
   (old-sum1 :type flt-vector :initarg :old-sum1 :reader old-sum1)
   (sum2 :type flt-vector :initarg :sum2 :reader sum2))
  (:documentation "Like NORMAL-SPARSITY-GRADIENT-SOURCE, but it needs
less memory because it only tracks average activation levels of nodes
independently (as opposed to simultaneous activations) and thus it may
produce the wrong gradient an example for which is when two connected
nodes are on a lot, but never at the same time. Clearly, it makes
little sense to change the weight but this is exactly what happens."))

(defun other-chunk (cloud chunk)
  (cond ((eq chunk (chunk1 cloud))
         (chunk2 cloud))
        ((eq chunk (chunk2 cloud))
         (chunk1 cloud))
        (t
         (assert nil))))

(defmethod initialize-instance :after
    ((sparsity normal-sparsity-gradient-source) &key &allow-other-keys)
  (unless (slot-boundp sparsity 'products)
    (setf (slot-value sparsity 'products)
          (make-flt-array (segment-size (cloud sparsity)))))
  (unless (slot-boundp sparsity 'old-products)
    (setf (slot-value sparsity 'old-products)
          (make-flt-array (segment-size (cloud sparsity))))))

(defmethod initialize-instance :after
    ((sparsity cheating-sparsity-gradient-source) &key &allow-other-keys)
  (unless (slot-boundp sparsity 'sum1)
    (setf (slot-value sparsity 'sum1)
          (make-flt-array (size (chunk sparsity)))))
  (unless (slot-boundp sparsity 'old-sum1)
    (setf (slot-value sparsity 'old-sum1)
          (make-flt-array (size (chunk sparsity))))
    (fill! (target sparsity) (old-sum1 sparsity)))
  (unless (slot-boundp sparsity 'sum2)
    (setf (slot-value sparsity 'sum2)
          (make-flt-array (size (other-chunk (cloud sparsity)
                                             (chunk sparsity)))))))

(defgeneric flush-accumulator (sparsity accumulator start n-inputs-in-batch)
  ;; Add DAMPING * OLD-PRODUCTS + (1 - DAMPING) * PRODUCTS to the
  ;; accumulator and zero PRODUCTS.
  (:method ((sparsity normal-sparsity-gradient-source)
            accumulator start n-inputs-in-batch)
    (let ((damping (damping sparsity))
          (cost (cost sparsity))
          (products (products sparsity))
          (old-products (old-products sparsity)))
      (lla:scal! damping old-products)
      (lla:axpy! (/ (- (flt 1) damping) n-inputs-in-batch)
                  products old-products)
      (lla:axpy! (* cost n-inputs-in-batch) old-products
                  (aops:displace accumulator (array-total-size old-products)
                                 start))
      (fill! (flt 0) products)))
  ;; Add DAMPING * OLD-SUM1 + (1 - DAMPING) * SUM1 to the accumulator
  ;; and zero SUM1.
  (:method ((sparsity cheating-sparsity-gradient-source)
            accumulator start n-inputs-in-batch)
    (let* ((damping (damping sparsity))
           (cost (cost sparsity))
           (sum1 (sum1 sparsity))
           (old-sum1 (old-sum1 sparsity))
           (sum2 (sum2 sparsity))
           (target (sparsity-target sparsity))
           (size1 (length sum1))
           (size2 (length sum2)))
      (lla:scal! damping old-sum1)
      (lla:axpy! (/ (- (flt 1) damping) n-inputs-in-batch) sum1 old-sum1)
      (lla:copy! old-sum1 sum1)
      (dotimes (i size1)
        (decf (aref sum1 i) target))
      (lla:gemm! cost sum1 sum2
                  (flt 1) (aops:reshape accumulator (list size1 size2)
                                        start)
                  :m size1 :n size2 :k 1
                  :lda 1 :ldb size2 :ldc size2)
      (fill! (flt 0) sum1)
      (fill! (flt 0) sum2))))

(defclass segmented-gd-sparse-bm-trainer (segmented-gd-bm-trainer)
  ((sparsity-gradient-sources
    :type list :initform ()
    :reader sparsity-gradient-sources)
   (sparser :initform nil :initarg :sparser :reader sparser))
  (:documentation "For the chunks with . Collect the average means
over samples in a batch and adjust weights in each cloud connected to
it so that the average is closer to SPARSITY-TARGET. This is
implemented by keeping track of the average means of the chunks
connected to it. The derivative is (M* (MATLISP:TRANSPOSE (M.-
C1-MEANS TARGET)) C2-MEANS) and this is added to derivative at the end
of the batch. Batch size comes from the superclass."))

(define-descriptions (trainer segmented-gd-sparse-bm-trainer :inheritp t)
  sparsity-gradient-sources)

(defmethod describe-object :after ((trainer segmented-gd-sparse-bm-trainer)
                                   stream)
  (dolist (sparsity (sparsity-gradient-sources trainer))
    (describe sparsity stream)))

(defun map-sparser (trainer bm)
  (let ((sparsities ()))
    (flet ((foo (cloud chunk)
             (when (and (not (conditioning-chunk-p chunk))
                        (find-trainer-for-segment cloud trainer))
               (let ((sparsity (funcall (sparser trainer) cloud chunk)))
                 (when sparsity
                   (push sparsity sparsities))))))
      ;; Iterate over segments (not clouds) that happens to include the
      ;; full clouds of a factored cloud.
      (dolist (cloud (list-segments bm))
        (foo cloud (chunk1 cloud))
        (foo cloud (chunk2 cloud))))
    (reverse sparsities)))

(defmethod initialize-trainer ((trainer segmented-gd-sparse-bm-trainer)
                               (bm bm))
  (call-next-method)
  (when (sparser trainer)
    (setf (slot-value trainer 'sparsity-gradient-sources)
          (map-sparser trainer bm))
    ;; Arrange for the sparsity gradient accumulator to be written to
    ;; the BATCH-GD-TRAINER accumulator at the end of the batch.
    (dolist (sparsity (sparsity-gradient-sources trainer))
      (with-segment-gradient-accumulator ((start accumulator)
                                          ((cloud sparsity) trainer))
        (let ((segment-trainer
                (find-trainer-for-segment (cloud sparsity) trainer)))
          (push (lambda ()
                  (flush-accumulator sparsity accumulator start
                                     (n-inputs-in-batch segment-trainer)))
                (before-update-hook segment-trainer)))))))

(defgeneric accumulate-sparsity-statistics (sparsity multiplier)
  (:method ((sparsity normal-sparsity-gradient-source) multiplier)
    (let* ((chunk (chunk sparsity))
           (cloud (cloud sparsity))
           (sparsity-target (sparsity-target sparsity))
           (old-nodes (old-nodes chunk)))
      (declare (type flt-vector old-nodes))
      (assert (not (eq (nodes chunk) (old-nodes chunk))))
      (copy-chunk-nodes chunk (means chunk) (old-nodes chunk))
      (dotimes (i (* (size chunk) (n-stripes chunk)))
        (decf (aref old-nodes i) sparsity-target))
      (multiple-value-bind (v1 v2)
          (if (eq chunk (chunk1 cloud))
              (values (old-nodes chunk) (means (chunk2 cloud)))
              (values (means (chunk1 cloud)) (old-nodes chunk)))
        (accumulate-cloud-statistics* cloud v1 v2 multiplier
                                      0 (products sparsity)))))
  (:method ((sparsity cheating-sparsity-gradient-source) multiplier)
    (let* ((chunk (chunk sparsity))
           (cloud (cloud sparsity))
           (other-chunk (other-chunk cloud chunk))
           (size1 (size chunk))
           (size2 (size other-chunk))
           (n-stripes (n-stripes chunk)))
      (assert (= n-stripes (n-stripes other-chunk)))
      ;; FIXME: MULTIPLIER
      (assert (= #.(flt 1) multiplier))
      (lla:gemm! (flt 1) (make-flt-array (list 1 n-stripes)
                                         :initial-element (flt 1))
                 (means chunk)
                 (flt 1) (sum1 sparsity)
                 :ldb size1 :ldc size1
                 :m 1 :n size1 :k n-stripes)
      (lla:gemm! (flt 1) (make-flt-array (list 1 n-stripes)
                                         :initial-element (flt 1))
                 (means other-chunk)
                 (flt 1) (sum2 sparsity)
                 :ldb size2 :ldc size2
                 :m 1 :n size2 :k n-stripes))))

(defmethod accumulate-positive-phase-statistics
    ((trainer segmented-gd-sparse-bm-trainer) (bm bm) &key (multiplier (flt 1)))
  (call-next-method)
  (dolist (sparsity (sparsity-gradient-sources trainer))
    (accumulate-sparsity-statistics sparsity multiplier)))


;;;; Common base class for MCMC based BM trainers

(defclass bm-mcmc-parameters ()
  ((visible-sampling
    :initform nil
    :initarg :visible-sampling
    :accessor visible-sampling
    :documentation "Controls whether visible nodes are sampled during
the learning or the mean field is used instead.")
   (hidden-sampling
    :initform :half-hearted
    :type (member nil :half-hearted t)
    :initarg :hidden-sampling
    :accessor hidden-sampling
    :documentation "Controls whether and how hidden nodes are sampled
during the learning or mean field is used instead. :HALF-HEARTED, the
default value, samples the hiddens but uses the hidden means to
calculate the effect of the positive and negative phases on the
gradient. The default should almost always be preferable to T, as it
is a less noisy estimate.")
   (n-gibbs
    :type (integer 1)
    :initform 1
    :initarg :n-gibbs
    :accessor n-gibbs
    :documentation "The number of steps of Gibbs sampling to perform.
This is how many full (HIDDEN -> VISIBLE -> HIDDEN) steps are taken
for CD learning, and how many times each chunk is sampled for PCD."))
  (:documentation "Paramaters for Markov Chain Monte Carlo based
trainers for BMs."))

(define-descriptions (bm bm-mcmc-parameters :inheritp t)
  visible-sampling hidden-sampling n-gibbs)


;;;; Contrastive Divergence (CD) learning for RBMs

(defclass rbm-cd-trainer (bm-mcmc-parameters segmented-gd-sparse-bm-trainer)
  ()
  (:documentation "A contrastive divergence based trainer for RBMs."))

(defmethod train-batch (batch (trainer rbm-cd-trainer) (rbm rbm))
  (loop for samples in (group batch (max-n-stripes rbm))
        do (set-input samples rbm)
        (with-versions ((gensym) (conditioning-chunks rbm))
          (positive-phase batch trainer rbm)
          (negative-phase batch trainer rbm)))
  (maybe-update-weights trainer (length batch)))

(defmethod positive-phase (batch (trainer rbm-cd-trainer) (rbm rbm))
  (set-hidden-mean/1 rbm)
  (when (hidden-sampling trainer)
    (sample-hidden rbm))
  (accumulate-positive-phase-statistics trainer rbm))

(defmethod negative-phase (batch (trainer rbm-cd-trainer) (rbm rbm))
  (let ((visible-sampling (visible-sampling trainer))
        (hidden-sampling (hidden-sampling trainer)))
    (loop for i below (n-gibbs trainer) do
          (when (and (not (zerop i)) hidden-sampling)
            (sample-hidden rbm))
          (set-visible-mean/1 rbm)
          (when visible-sampling
            (sample-visible rbm))
          (set-hidden-mean/1 rbm))
    (accumulate-negative-phase-statistics trainer rbm)))


;;;; Persistent Contrastive Divergence (PCD) learning

(define-slots-not-to-be-copied 'pcd chunk
  nodes means old-nodes inputs indices-present)

(defmethod copy-object-extra-initargs ((context (eql 'pcd)) (chunk chunk))
  `(:size ,(size chunk)
    :max-n-stripes ,(max-n-stripes chunk)))

(define-slots-not-to-be-copied 'pcd temporal-chunk
  next-node-inputs has-inputs-p)

(define-slots-not-to-be-copied 'pcd cloud
  cached-version1 cached-version2
  cached-activations1 cached-activations2)

(define-slots-to-be-shallow-copied 'pcd full-cloud
  weights)

(define-slots-not-to-be-copied 'pcd bm
  chunks max-n-stripes)

(define-slots-not-to-be-copied 'pcd dbm
  visible-chunks hidden-chunks)

(define-slots-to-be-shallow-copied 'pcd rbm
  dbn)

(defclass bm-pcd-trainer (bm-mcmc-parameters segmented-gd-sparse-bm-trainer)
  ((n-particles
    :type unsigned-byte
    :initarg :n-particles
    :reader n-particles
    :documentation "The number of persistent chains to run. Also known
as the number of fantasy particles.")
   (normal-chains
    :type bm
    :reader normal-chains
    :documentation "The BM being trained.")
   (persistent-chains
    :type bm
    :reader persistent-chains
    :documentation "A BM that keeps the states of the persistent
chains (each stripe is a chain), initialized from the BM being trained
by COPY with 'PCD as the context. Suitable for training BM and
RBM."))
  (:documentation "Persistent Contrastive Divergence trainer."))

(define-descriptions (trainer bm-pcd-trainer :inheritp t)
  (n-particles (n-stripes (persistent-chains trainer))))

(defmethod initialize-trainer ((trainer bm-pcd-trainer) (bm bm))
  (setf (slot-value trainer 'normal-chains) bm)
  (setf (slot-value trainer 'persistent-chains) (copy 'pcd bm))
  (setf (max-n-stripes (persistent-chains trainer)) (n-particles trainer))
  (call-next-method))

(defmethod train-batch (batch (trainer bm-pcd-trainer) (bm bm))
  (loop for samples in (group batch (max-n-stripes bm))
        do (set-input samples bm)
        (positive-phase batch trainer bm))
  (negative-phase batch trainer (persistent-chains trainer))
  (maybe-update-weights trainer (length batch)))

;;; If CLOUD is in the persistent chain, that is, it's a copy of a
;;; cloud in the normal BM then use the orignal as that's what the
;;; SEGMENTED-GD-BM-TRAINER was initialized with (and they, of course,
;;; share the weights).
(defmethod find-segment-gradient-accumulator (cloud (trainer bm-pcd-trainer))
  (if (find cloud (list-segments (persistent-chains trainer)))
      (find-segment-gradient-accumulator (find-cloud (name cloud)
                                                     (normal-chains trainer))
                                         trainer)
      (call-next-method)))

(defmethod positive-phase (batch (trainer bm-pcd-trainer) (bm bm))
  (set-hidden-mean bm)
  (when (eq t (hidden-sampling trainer))
    (sample-hidden bm))
  (accumulate-positive-phase-statistics trainer bm))

(defun check-no-self-connection (bm)
  (when (find-if (lambda (cloud)
                   (eq (chunk1 cloud) (chunk2 cloud)))
                 (clouds bm))
    (error "PCD is not implemented for chunks connected to themselves.")))

(defmethod negative-phase (batch (trainer bm-pcd-trainer) bm)
  (check-no-self-connection bm)
  (loop repeat (n-gibbs trainer) do
        (dolist (chunk (visible-chunks bm))
          (set-mean (list chunk) bm)
          (when (visible-sampling trainer)
            (sample-chunk chunk)))
        (dolist (chunk (hidden-chunks bm))
          (set-mean (list chunk) bm)
          (when (hidden-sampling trainer)
            (sample-chunk chunk))))
  (accumulate-negative-phase-statistics
   trainer bm
   ;; The number of persistent chains (or fantasy particles), that is,
   ;; N-STRIPES of PERSISTENT-CHAINS is not necessarily the same as
   ;; the batch size. Normalize so that positive and negative phase
   ;; has the same weight.
   :multiplier (/ (length batch)
                  (n-stripes (persistent-chains trainer)))))


;;;; Convenience, utilities

(defun inputs->nodes (bm)
  "Copy the previously clamped INPUTS to NODES as if SET-INPUT were
called with the same parameters."
  (map nil (lambda (chunk)
             (let ((inputs (inputs chunk)))
               (when inputs
                 (copy-chunk-nodes chunk inputs (nodes chunk)))))
       (visible-chunks bm)))

(defun nodes->inputs (bm)
  "Copy NODES to INPUTS."
  (map nil (lambda (chunk)
             (let ((inputs (inputs chunk)))
               (when inputs
                 (copy-chunk-nodes chunk (nodes chunk) inputs))))
       (visible-chunks bm)))

(defun reconstruction-rmse (chunks)
  "Return the squared norm of INPUTS - NODES not considering constant
or conditioning chunks that aren't reconstructed in any case. The
second value returned is the number of nodes that contributed to the
error."
  (let ((sum #.(flt 0))
        (n 0))
    (declare (type flt sum) (type index n) (optimize (speed 3)))
    (dolist (chunk chunks)
      (unless (conditioning-chunk-p chunk)
        (let ((inputs (the flt-vector (inputs chunk)))
              (nodes (nodes* chunk)))
          (do-stripes (chunk)
            (do-chunk (i chunk)
              (let ((x (aref inputs i))
                    (y (aref nodes i)))
                (incf sum (expt (- x y) 2))
                (incf n)))))))
    (values sum n)))

(defun reconstruction-error (bm)
  "Return the squared norm of INPUTS - NODES not considering constant
or conditioning chunks that aren't reconstructed in any case. The
second value returned is the number of nodes that contributed to the
error."
  (reconstruction-rmse (visible-chunks bm)))

(defun remove-if* (filter seq)
  (if filter
      (remove-if filter seq)
      seq))

(defun make-bm-reconstruction-rmse-counters-and-measurers (bm &key chunk-filter)
  (declare (ignore bm))
  (list (cons (make-instance 'rmse-counter)
              (lambda (samples bm)
                (declare (ignore samples))
                (reconstruction-rmse (remove-if* chunk-filter
                                                 (visible-chunks bm)))))))

(defun make-dbm-reconstruction-rmse-counters-and-measurers (dbm &key
                                                            chunk-filter)
  "Return a list of counter, measurer conses to keep track of
reconstruction rmse suitable for COLLECT-BM-MEAN-FIELD-ERRORS."
  (loop for i upfrom 0
        for layer in (butlast (layers dbm))
        collect (let ((i i)
                      (layer layer))
                  (cons (make-instance 'rmse-counter
                                       :prepend-name (format nil "level ~A" i))
                        (lambda (samples dbn)
                          (declare (ignore samples dbn))
                          (reconstruction-rmse
                           (remove-if* chunk-filter layer)))))))

(defun collect-bm-mean-field-errors
    (sampler bm &key
     (counters-and-measurers
      (make-bm-reconstruction-rmse-counters-and-measurers bm)))
  "Set the hidden and then the visible mean field and collect the
errors with COLLECT-BATCH-ERRORS. By default, return the
reconstruction rmse."
  (collect-batch-errors (lambda (samples)
                          (set-input samples bm)
                          (set-hidden-mean bm)
                          (set-visible-mean bm))
                        sampler bm counters-and-measurers))


;;;; Classification

(defclass softmax-label-chunk (softmax-chunk labeled) ())

(defmethod stripe-label ((chunk softmax-label-chunk) stripe)
  (with-stripes ((stripe chunk start end))
    (- (max-position (nodes chunk) start end)
       start)))

(defmethod classification-confidences ((chunk softmax-label-chunk) stripe)
  (with-stripes ((stripe chunk start end))
    (subseq (nodes chunk) start end)))

(defun make-chunk-reconstruction-misclassification-counters-and-measurers
    (chunks &key chunk-filter)
  (loop for chunk in (remove-if* chunk-filter chunks)
        for measurer = (maybe-make-misclassification-measurer chunk)
        when measurer
        collect
        (cons (make-instance 'misclassification-counter
                             :prepend-name (format nil "chunk ~A" (name chunk)))
              measurer)))

(defun make-chunk-reconstruction-cross-entropy-counters-and-measurers
    (chunks &key chunk-filter)
  (loop for chunk in (remove-if* chunk-filter chunks)
        for measurer = (maybe-make-cross-entropy-measurer chunk)
        when measurer
          collect
          (cons (make-instance 'cross-entropy-counter
                               :prepend-name (format nil "chunk ~A"
                                                     (name chunk)))
                measurer)))

(defun make-bm-reconstruction-misclassification-counters-and-measurers
    (bm &key chunk-filter)
  "Return a list of counter, measurer conses to keep track of cross
entropy error suitable for BM-MEAN-FIELD-ERRORS."
  (make-chunk-reconstruction-misclassification-counters-and-measurers
   (visible-chunks bm) :chunk-filter chunk-filter))

(defun make-bm-reconstruction-cross-entropy-counters-and-measurers
    (bm &key chunk-filter)
  "Return a list of counter, measurer conses to keep track of cross
entropy error suitable for BM-MEAN-FIELD-ERRORS."
  (make-chunk-reconstruction-cross-entropy-counters-and-measurers
   (visible-chunks bm) :chunk-filter chunk-filter))

(defun mark-labels-present (object)
  (dolist (chunk (chunks object))
    (when (labeledp chunk)
      (setf (indices-present chunk) nil))))

(defun mark-everything-present (object)
  (dolist (chunk (chunks object))
    (setf (indices-present chunk) nil)))

(defun collect-bm-mean-field-errors/labeled
    (sampler bm &key
     (counters-and-measurers
      (append
       (make-bm-reconstruction-misclassification-counters-and-measurers bm)
       (make-bm-reconstruction-cross-entropy-counters-and-measurers bm))))
  "Like COLLECT-BM-MEAN-FIELD-ERRORS but reconstruct the labels even
if they were missing."
  (collect-batch-errors (lambda (samples)
                          (set-input samples bm)
                          (set-hidden-mean bm)
                          (mark-labels-present bm)
                          (set-visible-mean bm))
                        sampler bm counters-and-measurers))
