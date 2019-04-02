#lang typed/racket/base

(provide (all-defined-out))

(require typed/racket/class)

(require "message.rkt")
(require "algorithm/pkcs/hash.rkt")

(define-type SSH-Host-Key<%>
  (Class (init-field [hash-algorithm PKCS#1-Hash]
                     [peer-name Symbol])
         [tell-key-name (-> Symbol)]
         [make-key/certificates (-> Bytes)]
         [make-signature (-> Bytes Bytes)]))

(define-type SSH-Key-Exchange<%>
  (Class (init [Vs String] [Vc String]
               [Is Bytes] [Ic Bytes]
               [hostkey (Instance SSH-Host-Key<%>)]
               [hash (-> Bytes Bytes)]
               [peer-name Symbol])
         [tell-message-group (-> Symbol)]
         [request (-> SSH-Message)]
         [response (-> SSH-Message (Option SSH-Message))]))