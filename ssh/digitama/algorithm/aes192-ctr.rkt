#lang typed/racket/base

;;; https://tools.ietf.org/html/rfc4253#section-8

(provide (all-defined-out))


#|
 p is a large safe prime
 g is a generator for a subgroup of GF(p)
 q is the order of the subgroup
 V_S is S's identification string
 V_C is C's identification string
 K_S is S's public host key
 I_C is C's SSH_MSG_KEXINIT message
 I_S is S's SSH_MSG_KEXINIT message
|#


(define ssh-dh-init-mpint : (-> Integer)
  (lambda []
    0))