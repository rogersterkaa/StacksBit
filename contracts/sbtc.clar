;; Mock sBTC token for testing
(impl-trait .sip-010-trait.sip-010-trait)

(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
  (ok true)
)

(define-public (get-name)
  (ok "Bitcoin")
)

(define-public (get-symbol)
  (ok "sBTC")
)

(define-public (get-decimals)
  (ok u8)
)

(define-public (get-total-supply)
  (ok u21000000000000000)
)

(define-public (get-balance (owner principal))
  (ok u0)
)

(define-public (get-balance-uint (owner principal))
  (ok u0)
)

(define-public (get-token-uri)
  (ok (some u"https://stacks.co/sbtc"))
)