#lang typed/racket/base

;;; https://tools.ietf.org/html/rfc4250
;;; https://tools.ietf.org/html/rfc4251

(provide (all-defined-out))

(require racket/unsafe/ops)

(require "datatype.rkt")
(require "../datatype.rkt")

(require "message/name.rkt")
(require "message/condition.rkt")

(require/typed "message/condition.rkt"
               [ssh-case-message-field-database (HashTable Symbol (Pairof Index (Listof (List* Symbol (Listof Any)))))])

(require (for-syntax racket/base))
(require (for-syntax racket/string))
(require (for-syntax racket/syntax))
(require (for-syntax racket/sequence))
(require (for-syntax syntax/parse))

(require (for-syntax "message/condition.rkt"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-for-syntax (ssh-message-constructors <ssh:msg>)
  (list (format-id <ssh:msg> "~a" (gensym (format "~a:" (syntax-e <ssh:msg>))))
        (format-id <ssh:msg> "make-~a" (syntax-e <ssh:msg>))))

(define-for-syntax (ssh-message-procedures <id>)
  (define <ssh:msg> (ssh-typeid <id>))
  (define ssh:msg (syntax-e <ssh:msg>))
  
  (list* <ssh:msg>
         (map (λ [fmt] (format-id <ssh:msg> fmt ssh:msg))
              (list "~a?" "~a-length" "~a->bytes" "unsafe-bytes->~a" "unsafe-bytes->~a*"))))

(define-for-syntax (ssh-message-arguments <field-declarations>)
  (define-values (kw-args seulav)
    (for/fold ([syns null] [slav null])
              ([<declaration> (in-syntax <field-declarations>)])
      (define-values (<kw-name> <argls> <value>) (ssh-struct-field <declaration>))
      (values (cons <kw-name> (cons <argls> syns))
              (cons <value> slav))))
  (list kw-args (reverse seulav)))

(define-for-syntax (ssh-message-field-transforms ssh:msg <fields> <FieldTypes>)
  (for/list ([<field> (in-syntax <fields>)]
             [<FType> (in-syntax <FieldTypes>)])
    (list (format-id <field> "~a-~a" ssh:msg (syntax-e <field>))
          (ssh-datum-pipeline 'define-ssh-messages <FType>))))

(define-for-syntax (ssh-make-bytes->bytes <n>)
  (define n (syntax-e <n>))

  (cond [(not (byte? n)) #'ssh-values]
        [else #`(λ [[braw : Bytes] [offset : Natural 0]] : (Values Bytes Natural)
                  (let ([end (+ offset #,n)])
                    (values (subbytes braw offset end) end)))]))

(define-for-syntax (ssh-make-ghost->bytes <T> <vs> <src>)
  (define vs (syntax->list <vs>))

  (cond [(null? vs) (raise-syntax-error 'ssh-make-ghost->bytes "SSH-Void requires a constant value as the argument" <src>)]
        [(> (length vs) 1) (raise-syntax-error 'ssh-make-ghost->bytes "SSH-Void requires only one constant value as the argument" <src> #false (cdr vs))])
  
  #`(λ [[braw : Bytes] [offset : Natural 0]] : (Values #,(syntax-e <T>) Natural)
      (values #,@(map syntax-e vs) offset)))

(define-for-syntax (ssh-datum-pipeline func <FType>)
  (case (syntax->datum <FType>)
    [(Boolean)     (list #'values #'ssh-boolean->bytes #'ssh-bytes->boolean #'values #'ssh-boolean-length)]
    [(Index)       (list #'values #'ssh-uint32->bytes  #'ssh-bytes->uint32  #'values #'ssh-uint32-length)]
    [(Natural)     (list #'values #'ssh-uint64->bytes  #'ssh-bytes->uint64  #'values #'ssh-uint64-length)]
    [(String)      (list #'values #'ssh-string->bytes  #'ssh-bytes->string  #'values #'ssh-string-length)]
    [(Bytes)       (list #'values #'ssh-bstring->bytes #'ssh-bytes->bstring #'values #'ssh-bstring-length)]
    [(Integer)     (list #'values #'ssh-mpint->bytes   #'ssh-bytes->mpint   #'values #'ssh-mpint-length)]
    [(Symbol)      (list #'values #'ssh-name->bytes    #'ssh-bytes->name    #'values #'ssh-name-length)]
    [else (with-syntax* ([(TypeOf T v ...) (let ([ft (syntax-e <FType>)]) (if (list? ft) ft (raise-syntax-error func "invalid SSH data type" <FType>)))]
                         [$type (ssh-symname #'T)])
            (case (syntax-e #'TypeOf)
              [(SSH-Bytes)       (list #'values                #'ssh-bytes->bytes    (ssh-make-bytes->bytes #'T)                   #'values #'bytes-length)]
              [(SSH-Symbol)      (list #'$type                 #'ssh-uint32->bytes   #'ssh-bytes->uint32                           #'$type  #'ssh-uint32-length)]
              [(SSH-Name-Listof) (list #'ssh-names->namelist   #'ssh-namelist->bytes #'ssh-bytes->namelist                         #'$type  #'ssh-namelist-length)]
              [(SSH-Void)        (list #'values                #'ssh-ghost->bytes    (ssh-make-ghost->bytes #'T #'(v ...) <FType>) #'values #'ssh-ghost-length)]
              [else (if (and (free-identifier=? #'TypeOf #'Listof) (free-identifier=? #'T #'Symbol))
                        (list #'values #'ssh-namelist->bytes #'ssh-bytes->namelist #'values #'ssh-namelist-length)
                        (raise-syntax-error func "invalid SSH data type" <FType>))]))]))

(define-syntax (define-message-interface stx)
  (syntax-case stx [:]
    [(_ id n ([field : FieldType defval ...] ...))
     (with-syntax* ([SSH-MSG (ssh-typename #'id)]
                    [(ssh:msg ssh:msg? ssh:msg-length ssh:msg->bytes unsafe-bytes->ssh:msg unsafe-bytes->ssh:msg*) (ssh-message-procedures #'id)]
                    [(constructor make-ssh:msg) (ssh-message-constructors #'ssh:msg)]
                    [([kw-args ...] [init-values ...]) (ssh-message-arguments #'([field FieldType defval ...] ...))]
                    [([field-ref (racket->ssh ssh->bytes bytes->ssh ssh->racket ssh-datum-length)] ...)
                     (ssh-message-field-transforms (syntax-e #'ssh:msg) #'(field ...) #'(FieldType ...))])
       (syntax/loc stx
         (begin (struct ssh:msg ssh-message ([field : FieldType] ...)
                  #:transparent #:constructor-name constructor #:type-name SSH-MSG)

                (define (make-ssh:msg kw-args ...) : SSH-MSG
                  (constructor n 'SSH-MSG init-values ...))

                (define ssh:msg-length : (-> SSH-MSG Positive-Integer)
                  (lambda [self]
                    (+ 1 ; message number
                       (ssh-datum-length (racket->ssh (field-ref self)))
                       ...)))

                (define ssh:msg->bytes : (SSH-Datum->Bytes SSH-MSG)
                  (case-lambda
                    [(self) (bytes-append (bytes n) (ssh->bytes (racket->ssh (field-ref self))) ...)]
                    [(self pool) (ssh:msg->bytes self pool 0)]
                    [(self pool offset) (let* ([offset++ (+ offset 1)]
                                               [offset++ (ssh->bytes (racket->ssh (field-ref self)) pool offset++)] ...)
                                          (bytes-set! pool offset n)
                                          offset++)]))
                
                (define unsafe-bytes->ssh:msg : (->* (Bytes) (Index) (Values SSH-MSG Natural))
                  (lambda [bmsg [offset 0]]
                    (let*-values ([(offset) (+ offset 1)]
                                  [(field offset) (bytes->ssh bmsg offset)] ...)
                      (values (constructor n 'SSH-MSG (ssh->racket field) ...)
                              offset))))

                (define unsafe-bytes->ssh:msg* : (->* (Bytes) (Index) SSH-MSG)
                  (lambda [bmsg [offset 0]]
                    (define-values (message end-index) (unsafe-bytes->ssh:msg bmsg offset))
                    message))

                (hash-set! ssh-message-length-database 'SSH-MSG
                           (λ [[self : SSH-Message]] (ssh:msg-length (assert self ssh:msg?))))
                  
                (hash-set! ssh-message->bytes-database 'SSH-MSG
                           (case-lambda
                             [([self : SSH-Message])
                              (ssh:msg->bytes (assert self ssh:msg?))]
                             [([self : SSH-Message] [pool : Bytes] [offset : Natural])
                              (ssh:msg->bytes (assert self ssh:msg?) pool offset)])))))]
    [(_ id n #:parent parent ([pield : PieldType pefval ...] ...) ([field : FieldType defval ...] ...))
     (with-syntax* ([SSH-MSG (ssh-typename #'id)]
                    [(ssh:msg ssh:msg? ssh:msg-length ssh:msg->bytes unsafe-bytes->ssh:msg unsafe-bytes->ssh:msg*) (ssh-message-procedures #'id)]
                    [(pssh:msg _ pssh:msg-length pssh:msg->bytes _ _) (ssh-message-procedures #'parent)]
                    [(constructor make-ssh:msg) (ssh-message-constructors #'ssh:msg)]
                    [([kw-args ...] [init-values ...]) (ssh-message-arguments #'([pield PieldType pefval ...] ... [field FieldType defval ...] ...))]
                    [([_ (_ _ parent-bytes->ssh parent-ssh->racket _)] ...)
                     (ssh-message-field-transforms (syntax-e #'pssh:msg) #'(pield ...) #'(PieldType ...))]
                    [([field-ref (racket->ssh ssh->bytes bytes->ssh ssh->racket ssh-datum-length)] ...)
                     (ssh-message-field-transforms (syntax-e #'ssh:msg) #'(field ...) #'(FieldType ...))])
       (syntax/loc stx
         (begin (struct ssh:msg pssh:msg ([field : FieldType] ...)
                  #:transparent #:constructor-name constructor #:type-name SSH-MSG)

                (define (make-ssh:msg kw-args ...) : SSH-MSG
                  (constructor n 'SSH-MSG init-values ...))

                (define ssh:msg-length : (-> SSH-MSG Positive-Integer)
                  (lambda [self]
                    (+ (pssh:msg-length self)
                       (ssh-datum-length (racket->ssh (field-ref self)))
                       ...)))

                (define ssh:msg->bytes : (SSH-Datum->Bytes SSH-MSG)
                  (case-lambda
                    [(self) (bytes-append (pssh:msg->bytes self) (ssh->bytes (racket->ssh (field-ref self))) ...)]
                    [(self pool) (ssh:msg->bytes self pool 0)]
                    [(self pool offset) (let* ([offset++ (pssh:msg->bytes self pool offset)]
                                               [offset++ (ssh->bytes (racket->ssh (field-ref self)) pool offset++)] ...)
                                          offset++)]))

                (define unsafe-bytes->ssh:msg : (->* (Bytes) (Index) (Values SSH-MSG Natural))
                  (lambda [bmsg [offset 0]]
                    (let*-values ([(offset) (+ offset 1)]
                                  [(pield offset) (parent-bytes->ssh bmsg offset)] ...
                                  [(field offset) (bytes->ssh bmsg offset)] ...)
                      (values (constructor n 'SSH-MSG (parent-ssh->racket pield) ... (ssh->racket field) ...)
                              offset))))

                (define unsafe-bytes->ssh:msg* : (->* (Bytes) (Index) SSH-MSG)
                  (lambda [bmsg [offset 0]]
                    (define-values (message end-index) (unsafe-bytes->ssh:msg bmsg offset))
                    message))

                (hash-set! ssh-message-length-database 'SSH-MSG
                           (λ [[self : SSH-Message]] (ssh:msg-length (assert self ssh:msg?))))
                  
                (hash-set! ssh-message->bytes-database 'SSH-MSG
                           (case-lambda
                             [([self : SSH-Message])
                              (ssh:msg->bytes (assert self ssh:msg?))]
                             [([self : SSH-Message] [pool : Bytes] [offset : Natural])
                              (ssh:msg->bytes (assert self ssh:msg?) pool offset)])))))]
    [(_ id n ([field : FieldType defval ...] ...) #:case key-field)
     (with-syntax* ([SSH-MSG (ssh-typename #'id)]
                    [key-field-index (ssh-field-index #'key-field #'(field ...) 0)]
                    [field-infos (ssh-case-message-fields #'n #'(field ...) #'(FieldType ...) #'([defval ...] ...) (syntax-e #'key-field-index))]
                    [_ (hash-set! ssh-case-message-field-database (syntax-e #'SSH-MSG) (syntax->datum #'field-infos))])
       (syntax/loc stx
         (begin (define-message-interface id n ([field : FieldType defval ...] ...))

                (hash-set! ssh-bytes->case-message-database 'SSH-MSG
                           (cons key-field-index ((inst make-hasheq Any Unsafe-SSH-Bytes->Message))))
                
                (hash-set! ssh-case-message-field-database 'SSH-MSG 'field-infos))))]
    [(_ id n #:parent parent ([pield : PieldType pefval ...] ...) ([field : FieldType defval ...] ...) #:case key-field)
     (with-syntax* ([SSH-MSG (ssh-typename #'id)]
                    [key-field-index (ssh-field-index #'key-field #'(field ...) (length (syntax->list #'(pield ...))))]
                    [field-infos (ssh-case-message-fields #'n #'(pield ... field ...) #'(PieldType ... FieldType ...) #'([pefval ...] ... [defval ...] ...)
                                                          (syntax-e #'key-field-index))]
                    [_ (hash-set! ssh-case-message-field-database (syntax-e #'SSH-MSG) (syntax->datum #'field-infos))])
       (syntax/loc stx
         (begin (define-message-interface id n #:parent parent ([pield : PieldType pefval ...] ...) ([field : FieldType defval ...] ...))

                (hash-set! ssh-bytes->case-message-database 'SSH-MSG
                           (cons key-field-index ((inst make-hasheq Any Unsafe-SSH-Bytes->Message))))
                
                (hash-set! ssh-case-message-field-database 'SSH-MSG 'field-infos))))]))

(define-syntax (define-message stx)
  (syntax-case stx [:]
    [(_ id n #:group gid (field-definition ...))
     (with-syntax* ([ssh:msg (ssh-typeid #'id)]
                    [SSH-MSG (ssh-typename #'id)]
                    [unsafe-bytes->ssh:msg (format-id #'ssh:msg "unsafe-bytes->~a" (syntax-e #'ssh:msg))])
       (syntax/loc stx
         (begin (define-message-interface id n (field-definition ...))
                
                (let ([database ((inst hash-ref! Symbol (HashTable Index Unsafe-SSH-Bytes->Message))
                                 ssh-bytes->shared-message-database 'gid (λ [] (make-hasheq)))])
                  (hash-set! database n unsafe-bytes->ssh:msg))

                (let ([names (hash-ref ssh-message-name-database n (λ [] null))])
                  (when (list? names)
                    (hash-set! ssh-message-name-database n
                               (cons 'SSH-MSG names)))))))]
    [(_ id n (field-definition ...) conditions ...)
     (with-syntax* ([ssh:msg (ssh-typeid #'id)]
                    [SSH-MSG (ssh-typename #'id)]
                    [unsafe-bytes->ssh:msg (format-id #'ssh:msg "unsafe-bytes->~a" (syntax-e #'ssh:msg))])
       (syntax/loc stx
         (begin (define-message-interface id n (field-definition ...) conditions ...)

                (unless (hash-has-key? ssh-bytes->message-database n)
                  (hash-set! ssh-bytes->message-database n unsafe-bytes->ssh:msg))

                (hash-set! ssh-message-name-database n 'SSH-MSG))))]
    [(_ id n #:parent parent (parent-field-definition ...) (field-definition ...) conditions ...)
     (syntax/loc stx
       (begin (define-message-interface id n #:parent parent
                (parent-field-definition ...) (field-definition ...) conditions ...)

              #| messages that have a parent have already had their number registered |#))]))

(define-syntax (define-ssh-case-message stx)
  (syntax-parse stx #:literals [:]
    [(_ id id-suffix datum:keyword case-value ([field:id : FieldType defval ...] ...) conditions ...)
     (with-syntax* ([PSSH-MSG (ssh-typename #'id)]
                    [SSH-MSG (ssh-typename* #'id #'id-suffix)]
                    [ssh:msg (ssh-typeid #'SSH-MSG)]
                    [unsafe-bytes->ssh:msg (format-id #'ssh:msg "unsafe-bytes->~a" (syntax-e #'ssh:msg))]
                    [(n [pield-field PieldType smart_defval ...] ...)
                     (ssh-case-message-shared-fields ssh-case-message-field-database #'PSSH-MSG #'datum #'case-value)])
       (syntax/loc stx
         (begin (define-message SSH-MSG n #:parent PSSH-MSG
                  ([pield-field : PieldType smart_defval ...] ...)
                  ([field : FieldType defval ...] ...)
                  conditions ...)

                (hash-set! (cdr (hash-ref ssh-bytes->case-message-database 'PSSH-MSG))
                           case-value unsafe-bytes->ssh:msg))))]))

(define-syntax (define-ssh-messages stx)
  (syntax-parse stx #:literals [:]
    [(_ [enum:id n:nat ([field:id : FieldType defval ...] ...) conditions ...] ...)
     (syntax/loc stx (begin (define-message enum n ([field : FieldType defval ...] ...) conditions ...) ...))]))

(define-syntax (define-ssh-shared-messages stx)
  (syntax-parse stx #:literals [:]
    [(_ group-name:id [enum:id n:nat ([field:id : FieldType defval ...] ...)] ...)
     (syntax/loc stx (begin (define-message enum n #:group group-name ([field : FieldType defval ...] ...)) ...))]))

(define-syntax (define-ssh-case-messages stx)
  (syntax-parse stx #:literals [:]
    [(_ id [id-suffix datum:keyword case-value ([field:id : FieldType defval ...] ...) conditions ...] ...)
     (syntax/loc stx (begin (define-ssh-case-message id id-suffix datum case-value ([field : FieldType defval ...] ...) conditions ...) ...))]))

(define-syntax (define-ssh-message-range stx)
  (syntax-case stx [:]
    [(_ type idmin idmax comments ...)
     (with-syntax ([ssh-range (format-id #'type "ssh-~a-range" (syntax-e #'type))]
                   [ssh-range-payload? (format-id #'type "ssh-~a-payload?" (syntax-e #'type))]
                   [ssh-range-message? (format-id #'type "ssh-~a-message?" (syntax-e #'type))]
                   [ssh-bytes->range-message (format-id #'type "ssh-bytes->~a-message" (syntax-e #'type))]
                   [ssh-bytes->range-message* (format-id #'type "ssh-bytes->~a-message*" (syntax-e #'type))])
       (syntax/loc stx
         (begin (define ssh-range : (Pairof Index Index) (cons idmin idmax))

                (define ssh-range-payload? : (->* (Bytes) (Index) Boolean)
                  (lambda [src [offset 0]]
                    (<= idmin (ssh-message-payload-number src offset) idmax)))

                (define ssh-range-message? : (-> Any Boolean : #:+ SSH-Message)
                  (lambda [self]
                    (and (ssh-message? self)
                         (<= idmin (ssh-message-number self) idmax))))
                
                (define ssh-bytes->range-message : (->* (Bytes) (Index #:group (Option Symbol)) (values (Option SSH-Message) Natural))
                  (lambda [bmsg [offset 0] #:group [group #false]]
                    (cond [(<= idmin (bytes-ref bmsg offset) idmax) (ssh-bytes->message bmsg offset #:group group)]
                          [else (values #false offset)])))

                (define ssh-bytes->range-message* : (->* (Bytes) (Index #:group (Option Symbol)) (Option SSH-Message))
                  (lambda [bmsg [offset 0] #:group [group #false]]
                    (define-values (maybe-message end-index) (ssh-bytes->message bmsg offset #:group group))
                    maybe-message)))))]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-type Unsafe-SSH-Bytes->Message (->* (Bytes) (Index) (Values SSH-Message Natural)))
(define-type SSH-Message->Bytes (case-> [SSH-Message -> Bytes] [SSH-Message Bytes Natural -> Natural]))

(struct ssh-message ([number : Byte] [name : Symbol]) #:type-name SSH-Message)
(struct ssh-message-undefined ssh-message () #:type-name SSH-Message-Undefined)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define ssh-message-payload-number : (->* (Bytes) (Index) Byte)
  (lambda [bmsg [offset 0]]
    (bytes-ref bmsg offset)))

(define ssh-message-length : (-> SSH-Message Natural)
  (lambda [self]
    ((hash-ref ssh-message-length-database (ssh-message-name self)) self)))

(define ssh-message->bytes : (SSH-Datum->Bytes SSH-Message)
  (case-lambda
    [(self) ((hash-ref ssh-message->bytes-database (ssh-message-name self)) self)]
    [(self pool) (ssh-message->bytes self pool 0)]
    [(self pool offset) ((hash-ref ssh-message->bytes-database (ssh-message-name self)) self pool offset)]))

(define ssh-bytes->message : (->* (Bytes) (Index #:group (Option Symbol)) (Values SSH-Message Natural))
  (lambda [bmsg [offset 0] #:group [group #false]]
    (define id : Byte (ssh-message-payload-number bmsg offset))
    (define-values (msg end)
      (let ([unsafe-bytes->message (hash-ref ssh-bytes->message-database id (λ [] #false))])
        (cond [(and unsafe-bytes->message) (unsafe-bytes->message bmsg offset)]
              [else (let ([bytes->message (ssh-bytes->shared-message group id)])
                      (cond [(not bytes->message) (values (ssh-undefined-message id) offset)]
                            [else (bytes->message bmsg offset)]))])))
    
    (let message->conditional-message ([msg : SSH-Message msg]
                                       [end : Natural end])
      (define name : Symbol (ssh-message-name msg))
      (cond [(hash-has-key? ssh-bytes->case-message-database name)
             (let ([case-info (hash-ref ssh-bytes->case-message-database name)])
               (define key : Any (unsafe-struct*-ref msg (car case-info)))
               (define bytes->case-message : (Option Unsafe-SSH-Bytes->Message) (hash-ref (cdr case-info) key (λ [] #false)))
               (cond [(and bytes->case-message) (call-with-values (λ [] (bytes->case-message bmsg offset)) message->conditional-message)]
                     [else (values msg end)]))]
            [else (values msg end)]))))

(define ssh-bytes->message* : (->* (Bytes) (Index #:group (Option Symbol)) SSH-Message)
  (lambda [bmsg [offset 0] #:group [group #false]]
    (define-values (message end-index) (ssh-bytes->message bmsg offset #:group group))
    message))

(define ssh-bytes-uint32-car : (->* (Bytes) (Index) Index)
  (lambda [bmsg [offset 0]]
    (define-values (u32 _) (ssh-bytes->uint32 bmsg (+ offset 1)))
    u32))

(define ssh-message-number->name : (-> Index (U Symbol (Listof Symbol) False))
  (lambda [n]
    (hash-ref ssh-message-name-database n (λ [] #false))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define ssh-bytes->shared-message-database : (HashTable Symbol (HashTable Index Unsafe-SSH-Bytes->Message)) (make-hasheq))
(define ssh-bytes->case-message-database : (HashTable Symbol (cons Index (HashTable Any Unsafe-SSH-Bytes->Message))) (make-hasheq))
(define ssh-bytes->message-database : (HashTable Index Unsafe-SSH-Bytes->Message) (make-hasheq))
(define ssh-message->bytes-database : (HashTable Symbol SSH-Message->Bytes) (make-hasheq))
(define ssh-message-length-database : (HashTable Symbol (-> SSH-Message Natural)) (make-hasheq))
(define ssh-message-name-database : (HashTable Index (U Symbol (Listof Symbol))) (make-hasheq))

(define ssh-undefined-message : (-> Byte SSH-Message-Undefined)
  (lambda [id]
    (ssh-message-undefined id 'SSH-MSG-UNDEFINED)))

(define ssh-bytes->shared-message : (-> (Option Symbol) Index (Option Unsafe-SSH-Bytes->Message))
  (lambda [gid no]
    (and gid
         (let ([maybe-db (hash-ref ssh-bytes->shared-message-database gid (λ [] #false))])
           (and (hash? maybe-db)
                (hash-ref maybe-db no (λ [] #false)))))))
