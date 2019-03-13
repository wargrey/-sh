#lang typed/racket/base

(provide (all-defined-out))

(require (for-syntax racket/base))
(require (for-syntax racket/syntax))
(require (for-syntax syntax/parse))

(define-type SSH-Error exn:ssh)

(struct exn:ssh exn:fail:network ())
(struct exn:ssh:defense exn:ssh ())
(struct exn:ssh:identification exn:ssh ())

(define ssh-error-logger-topic : Symbol 'exn:ssh)

(define-syntax (throw stx)
  (syntax-parse stx
    [(_ st:id /dev/ssh rest ...)
     #'(throw [st] /dev/ssh rest ...)]
    [(_ [st:id argl ...] /dev/ssh src frmt:str v ...)
     #'(let ([errobj (st (format (string-append "~a: ~s: " frmt) (object-name /dev/ssh) src v ...) (current-continuation-marks) argl ...)])
         (ssh-log-error errobj)
         (raise errobj))]))

(define ssh-raise-timeout-error : (->* (Port Symbol Real) (String) Void)
  (lambda [/dev/ssh func seconds [message "timer break"]]
    (call-with-escape-continuation
        (λ [[ec : Procedure]]
          (raise (make-exn:break (format "~a: ~a: ~a: ~as" (object-name /dev/ssh) func message seconds)
                                 (current-continuation-marks)
                                 ec))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define ssh-log-error : (->* (SSH-Error) (Log-Level) Void)
  (lambda [errobj [level 'error]]
    (log-message (current-logger)
                 level
                 ssh-error-logger-topic
                 (format "~a: ~a" (object-name errobj) (exn-message errobj))
                 errobj)))
