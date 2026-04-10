;; StacksBit Fraud Detection Contract
;; On-chain fraud signals and merchant reputation tracking
;;
;; Author: Terkaa Tarkighir (rogersterkaa@gmail.com)
;; License: MIT

;; ============================================
;; Error Codes
;; ============================================

(define-constant ERR-NOT-AUTHORIZED (err u500))
(define-constant ERR-NOT-GATEWAY (err u501))
(define-constant ERR-MERCHANT-NOT-FOUND (err u510))
(define-constant ERR-ALREADY-BLACKLISTED (err u511))
(define-constant ERR-NOT-BLACKLISTED (err u512))

;; ============================================
;; Data Variables
;; ============================================

(define-data-var contract-owner principal tx-sender)
(define-data-var gateway-contract (optional principal) none)

;; ============================================
;; Merchant Reputation Map
;; Tracks on-chain fraud signals per merchant
;; ============================================

(define-map merchant-reputation principal {
  total-payments: uint,
  total-disputes: uint,
  disputes-last-30-days: uint,
  last-dispute-block: uint,
  is-blacklisted: bool,
  risk-score: uint,
  flagged-at: (optional uint)
})

;; ============================================
;; Blacklisted Addresses
;; ============================================

(define-map blacklist principal bool)

;; ============================================
;; Suspicious Transaction Map
;; ============================================

(define-map suspicious-payments uint {
  payment-id: uint,
  merchant: principal,
  reason: (string-ascii 100),
  flagged-at: uint
})

(define-data-var suspicious-payment-count uint u0)

;; ============================================
;; Authorization
;; ============================================

(define-private (is-gateway)
  (match (var-get gateway-contract)
    gw (is-eq tx-sender gw)
    false
  )
)

(define-private (is-owner)
  (is-eq tx-sender (var-get contract-owner))
)

;; ============================================
;; Read-Only Functions
;; ============================================

(define-read-only (get-merchant-reputation (merchant principal))
  (map-get? merchant-reputation merchant)
)

(define-read-only (is-blacklisted (address principal))
  (default-to false (map-get? blacklist address))
)

(define-read-only (get-risk-score (merchant principal))
  (match (map-get? merchant-reputation merchant)
    rep (get risk-score rep)
    u0
  )
)

(define-read-only (get-suspicious-payment (id uint))
  (map-get? suspicious-payments id)
)

(define-read-only (is-high-risk (merchant principal))
  (>= (get-risk-score merchant) u70)
)

(define-read-only (is-medium-risk (merchant principal))
  (and
    (>= (get-risk-score merchant) u40)
    (< (get-risk-score merchant) u70)
  )
)

;; ============================================
;; Core Fraud Detection Functions
;; ============================================

;; Called when a payment is created
;; Increments merchant total payments
(define-public (record-payment (merchant principal))
  (begin
    (asserts! (or (is-gateway) (is-owner)) ERR-NOT-AUTHORIZED)
    (match (map-get? merchant-reputation merchant)
      rep (begin
        (map-set merchant-reputation merchant
          (merge rep {
            total-payments: (+ (get total-payments rep) u1)
          })
        )
        (ok true)
      )
      (begin
        ;; First payment - initialize reputation
        (map-set merchant-reputation merchant {
          total-payments: u1,
          total-disputes: u0,
          disputes-last-30-days: u0,
          last-dispute-block: u0,
          is-blacklisted: false,
          risk-score: u10,
          flagged-at: none
        })
        (ok true)
      )
    )
  )
)

;; Called when a dispute is raised
;; Updates dispute count and recalculates risk score
(define-public (record-dispute (merchant principal))
  (begin
    (asserts! (or (is-gateway) (is-owner)) ERR-NOT-AUTHORIZED)
    (match (map-get? merchant-reputation merchant)
      rep (let
        (
          (new-total-disputes (+ (get total-disputes rep) u1))
          (new-disputes-30 (+ (get disputes-last-30-days rep) u1))
          (new-risk-score (calculate-risk-score
            (get total-payments rep)
            new-total-disputes
            new-disputes-30
            (get is-blacklisted rep)
          ))
        )
        (map-set merchant-reputation merchant
          (merge rep {
            total-disputes: new-total-disputes,
            disputes-last-30-days: new-disputes-30,
            last-dispute-block: stacks-block-height,
            risk-score: new-risk-score
          })
        )
        (ok new-risk-score)
      )
      (begin
        ;; Merchant not found - initialize with dispute
        (map-set merchant-reputation merchant {
          total-payments: u0,
          total-disputes: u1,
          disputes-last-30-days: u1,
          last-dispute-block: stacks-block-height,
          is-blacklisted: false,
          risk-score: u50,
          flagged-at: none
        })
        (ok u50)
      )
    )
  )
)

;; Flag a suspicious payment
(define-public (flag-suspicious-payment
  (payment-id uint)
  (merchant principal)
  (reason (string-ascii 100))
)
  (let
    (
      (flag-id (var-get suspicious-payment-count))
    )
    (asserts! (or (is-gateway) (is-owner)) ERR-NOT-AUTHORIZED)
    (map-set suspicious-payments flag-id {
      payment-id: payment-id,
      merchant: merchant,
      reason: reason,
      flagged-at: stacks-block-height
    })
    (var-set suspicious-payment-count (+ flag-id u1))
    (ok flag-id)
  )
)

;; Blacklist a merchant address
(define-public (blacklist-merchant (merchant principal))
  (begin
    (asserts! (is-owner) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-blacklisted merchant)) ERR-ALREADY-BLACKLISTED)
    (map-set blacklist merchant true)
    (match (map-get? merchant-reputation merchant)
      rep (map-set merchant-reputation merchant
        (merge rep {
          is-blacklisted: true,
          risk-score: u100,
          flagged-at: (some stacks-block-height)
        })
      )
      (map-set merchant-reputation merchant {
        total-payments: u0,
        total-disputes: u0,
        disputes-last-30-days: u0,
        last-dispute-block: u0,
        is-blacklisted: true,
        risk-score: u100,
        flagged-at: (some stacks-block-height)
      })
    )
    (print { event: "merchant-blacklisted", merchant: merchant, block: stacks-block-height})
    (ok true)
  )
)

;; Remove merchant from blacklist
(define-public (remove-from-blacklist (merchant principal))
  (begin
    (asserts! (is-owner) ERR-NOT-AUTHORIZED)
    (asserts! (is-blacklisted merchant) ERR-NOT-BLACKLISTED)
    (map-set blacklist merchant false)
    (match (map-get? merchant-reputation merchant)
      rep (map-set merchant-reputation merchant
        (merge rep {
          is-blacklisted: false,
          risk-score: u30,
          flagged-at: none
        })
      )
      true
    )
    (print { event: "merchant-unblacklisted", merchant: merchant })
    (ok true)
  )
)

;; ============================================
;; Risk Score Calculator
;; Score 0-100 (higher = more risky)
;; ============================================

(define-private (calculate-risk-score
  (total-payments uint)
  (total-disputes uint)
  (disputes-30-days uint)
  (blacklisted bool)
)
  (if blacklisted
    u100
    (let
      (
        ;; Base score starts at 10
        (base u10)

        ;; Dispute rate penalty
        ;; More than 3 disputes in 30 days = +40
        (dispute-30-penalty
          (if (>= disputes-30-days u3) u40
            (if (>= disputes-30-days u2) u25
              (if (>= disputes-30-days u1) u10
                u0
              )
            )
          )
        )

        ;; New merchant penalty (fewer than 5 payments = +20)
        (new-merchant-penalty
          (if (< total-payments u5) u20
            (if (< total-payments u10) u10
              u0
            )
          )
        )

        ;; Established merchant bonus (more than 50 payments = -10)
        (established-bonus
          (if (>= total-payments u50) u10
            (if (>= total-payments u20) u5
              u0
            )
          )
        )

        (raw-score (+
          (+ base dispute-30-penalty)
          new-merchant-penalty
        ))
      )
      ;; Subtract bonus but don't go below 0
      (if (> raw-score established-bonus)
        (- raw-score established-bonus)
        u0
      )
    )
  )
)

;; ============================================
;; Admin Functions
;; ============================================

(define-public (set-gateway (new-gateway principal))
  (begin
    (asserts! (is-owner) ERR-NOT-AUTHORIZED)
    (var-set gateway-contract (some new-gateway))
    (ok true)
  )
)

(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-owner) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)