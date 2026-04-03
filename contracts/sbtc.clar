;; StacksBit Mock sBTC Token
;; Full SIP-010 compliant with real balance tracking

(impl-trait .sip-010-trait.sip-010-trait)

(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-INSUFFICIENT-BALANCE (err u402))
(define-constant ERR-INVALID-AMOUNT (err u403))
(define-constant ERR-INVALID-SENDER (err u404))

(define-data-var contract-owner principal tx-sender)
(define-data-var total-supply uint u0)

(define-map balances principal uint)

(define-read-only (get-balance-uint (owner principal))
  (default-to u0 (map-get? balances owner))
)

(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
  (begin
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (is-eq tx-sender sender) ERR-INVALID-SENDER)
    (asserts! (>= (get-balance-uint sender) amount) ERR-INSUFFICIENT-BALANCE)
    (map-set balances sender (- (get-balance-uint sender) amount))
    (map-set balances recipient (+ (get-balance-uint recipient) amount))
    (ok true)
  )
)

(define-read-only (get-name) (ok "Stacks Bitcoin"))
(define-read-only (get-symbol) (ok "sBTC"))
(define-read-only (get-decimals) (ok u8))
(define-read-only (get-balance (owner principal)) (ok (get-balance-uint owner)))
(define-read-only (get-total-supply) (ok (var-get total-supply)))
(define-read-only (get-token-uri) (ok (some u"https://stacks.co/sbtc")))

(define-public (mint (amount uint) (recipient principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (map-set balances recipient (+ (get-balance-uint recipient) amount))
    (var-set total-supply (+ (var-get total-supply) amount))
    (ok true)
  )
)