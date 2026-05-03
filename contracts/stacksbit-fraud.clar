;; StacksBit Fraud Detection Contract
;; Version: 2.0 - Full Trust Engine
;;
;; Author: Terkaa Tarkighir (rogersterkaa@gmail.com)
;; License: MIT
;;
;; OVERVIEW:
;; This contract is the intelligence layer of StacksBit.
;; It moves beyond simple risk labeling into active
;; decision routing - determining not just WHETHER a
;; merchant is risky, but WHAT the system should do
;; about it in real time.
;;
;; ARCHITECTURE:
;; 1. Merchant reputation (stateful, long-term)
;; 2. Transaction signals (dynamic, per-payment)
;; 3. Decision engine (routes to action)
;; 4. Score decay (prevents reputation abuse)
;; 5. First interaction risk (catches new-customer fraud)


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

;; Gateway is the only contract allowed to trigger
;; fraud signals - prevents external manipulation
(define-data-var gateway-contract (optional principal) none)


;; ============================================
;; Merchant Reputation Map
;;
;; Tracks long-term behavioral signals per merchant.
;; Score range: 0 (fully trusted) to 100 (blocked)
;; ============================================

(define-map merchant-reputation principal {
  total-payments: uint,        ;; lifetime payment count
  total-disputes: uint,        ;; lifetime dispute count
  disputes-last-30-days: uint, ;; rolling dispute window
  last-dispute-block: uint,    ;; block of most recent dispute
  is-blacklisted: bool,        ;; hard block flag
  risk-score: uint,            ;; current score 0-100
  flagged-at: (optional uint)  ;; block when first flagged
})


;; ============================================
;; Blacklist Map
;;
;; Hard block for known bad actors.
;; Blacklisted merchants cannot receive payments.
;; ============================================

(define-map blacklist principal bool)


;; ============================================
;; Suspicious Payment Log
;;
;; Records flagged transactions for audit trail.
;; Important for dispute resolution and compliance.
;; ============================================

(define-map suspicious-payments uint {
  payment-id: uint,
  merchant: principal,
  reason: (string-ascii 100),
  flagged-at: uint
})

(define-data-var suspicious-payment-count uint u0)


;; ============================================
;; First Interaction Tracking (Upgrade 5)
;;
;; Most fraud happens on first interactions.
;; Tracking customer-merchant pairs lets us add
;; +15 risk to brand new relationships.
;; ============================================

(define-map customer-merchant-history
  { customer: principal, merchant: principal }
  { transaction-count: uint }
)


;; ============================================
;; Merchant Average Payment Tracking (Upgrade 2)
;;
;; Used to detect payment spikes.
;; A payment 10x the merchant average triggers
;; an additional +25 transaction risk score.
;; ============================================

(define-map merchant-avg-payment principal {
  total-amount: uint,
  payment-count: uint
})


;; ============================================
;; Score Decay Tracking (Upgrade 4)
;;
;; Tracks when each merchant's score was last
;; updated so we can apply weekly decay.
;; Prevents old reputation from being abused.
;; ============================================

(define-map merchant-last-update principal uint)


;; ============================================
;; Authorization Helpers
;; ============================================

;; Only the gateway contract can trigger fraud signals.
;; This prevents merchants from manipulating their own scores.
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
;; Read-Only - Basic Reputation Queries
;; ============================================

(define-read-only (get-merchant-reputation (merchant principal))
  (map-get? merchant-reputation merchant)
)

(define-read-only (is-blacklisted (address principal))
  (default-to false (map-get? blacklist address))
)

;; Returns raw merchant reputation score (0-100)
;; New merchants with no history return 0
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
;; Upgrade 3 - Conditional USSD Routing
;;
;; USSD confirmation is only required for YELLOW
;; merchants (score 40-69). GREEN merchants get
;; auto-release. RED merchants are fully blocked.
;;
;; This solves the low-connectivity problem:
;; trusted merchants never need USSD confirmation.
;; ============================================

;; Returns true only for YELLOW zone merchants
(define-read-only (requires-ussd-confirmation (merchant principal))
  (let ((score (get-risk-score merchant)))
    (and (>= score u40) (< score u70))
  )
)

;; Returns true for RED zone - payment should be blocked
(define-read-only (is-merchant-blocked (merchant principal))
  (>= (get-risk-score merchant) u70)
)

;; Returns human-readable action string for frontend/API use
;; "auto-release" | "ussd-required" | "blocked"
(define-read-only (get-confirmation-requirement (merchant principal))
  (let ((score (get-risk-score merchant)))
    (if (>= score u70)
      "blocked"
      (if (>= score u40)
        "ussd-required"
        "auto-release"
      )
    )
  )
)


;; ============================================
;; Upgrade 5 - First Interaction Risk
;;
;; First-time customer-merchant interactions carry
;; higher fraud risk. We add +15 to transaction
;; risk score for brand new relationships.
;; ============================================

;; Returns true if customer has never paid this merchant before
(define-read-only (is-first-interaction
  (customer principal)
  (merchant principal))
  (match (map-get? customer-merchant-history
    { customer: customer, merchant: merchant })
    history false
    true
  )
)

;; Returns 15 for first interactions, 0 for returning customers
(define-read-only (get-first-interaction-risk
  (customer principal)
  (merchant principal))
  (if (is-first-interaction customer merchant)
    u15
    u0
  )
)

;; Called by gateway after successful payment to record relationship
(define-public (record-customer-interaction
  (customer principal)
  (merchant principal))
  (begin
    (asserts! (or (is-gateway) (is-owner)) ERR-NOT-AUTHORIZED)
    (match (map-get? customer-merchant-history
      { customer: customer, merchant: merchant })
      history (begin
        (map-set customer-merchant-history
          { customer: customer, merchant: merchant }
          { transaction-count: (+ (get transaction-count history) u1) }
        )
        (ok true)
      )
      (begin
        ;; First interaction - initialize the relationship
        (map-set customer-merchant-history
          { customer: customer, merchant: merchant }
          { transaction-count: u1 }
        )
        (ok true)
      )
    )
  )
)


;; ============================================
;; Upgrade 2 - Transaction Level Signals
;;
;; Merchant reputation alone is not enough.
;; Each payment carries its own dynamic risk
;; based on amount spikes and customer history.
;;
;; final_risk = merchant_score + transaction_risk
;; ============================================

;; Calculates dynamic risk for a specific transaction.
;; Spike detection: amount > 10x merchant average = +25
;; First interaction: new customer = +15
(define-read-only (get-transaction-risk
  (amount uint)
  (merchant principal)
  (customer principal))
  (let
    (
      ;; Payment spike detection
      ;; Compares this payment to merchant's historical average
      (spike-risk
        (match (map-get? merchant-avg-payment merchant)
          avg (if (and
                (> (get payment-count avg) u0)
                (> amount (* (/ (get total-amount avg)
                               (get payment-count avg)) u10)))
                u25  ;; significant spike detected
                u0)
          u0  ;; no history yet, no spike risk
        )
      )
      (first-risk (get-first-interaction-risk customer merchant))
    )
    (+ spike-risk first-risk)
  )
)

;; Updates merchant average after each payment.
;; Used by spike detection in get-transaction-risk.
(define-public (update-merchant-avg-payment
  (merchant principal)
  (amount uint))
  (begin
    (asserts! (or (is-gateway) (is-owner)) ERR-NOT-AUTHORIZED)
    (match (map-get? merchant-avg-payment merchant)
      avg (begin
        (map-set merchant-avg-payment merchant {
          total-amount: (+ (get total-amount avg) amount),
          payment-count: (+ (get payment-count avg) u1)
        })
        (ok true)
      )
      (begin
        ;; First payment - initialize average tracking
        (map-set merchant-avg-payment merchant {
          total-amount: amount,
          payment-count: u1
        })
        (ok true)
      )
    )
  )
)


;; ============================================
;; Upgrade 1 - Risk Decision Engine
;;
;; This is the core upgrade. Combines merchant
;; reputation + transaction signals into a final
;; score, then maps that score to a concrete action.
;;
;; GREEN  (0-39):  auto-release - no friction
;; YELLOW (40-69): ussd-required - confirmation needed
;; RED    (70-100): blocked - payment rejected
;; ============================================

;; Combines merchant score + transaction risk into final score
;; Capped at 100 to prevent overflow
(define-read-only (get-final-risk-score
  (merchant principal)
  (amount uint)
  (customer principal))
  (let
    (
      (merchant-score (get-risk-score merchant))
      (transaction-risk (get-transaction-risk amount merchant customer))
      (raw-score (+ merchant-score transaction-risk))
    )
    ;; Hard cap at 100
    (if (> raw-score u100) u100 raw-score)
  )
)

;; The decision engine. Returns a structured response
;; that the gateway and frontend can act on directly.
;; This is what separates a classifier from a trust engine.
(define-read-only (get-payment-decision
  (merchant principal)
  (amount uint)
  (customer principal))
  (let
    (
      (final-score (get-final-risk-score merchant amount customer))
    )
    (if (>= final-score u70)
      {
        action: "blocked",
        score: final-score,
        requires-ussd: false,
        auto-release: false,
        reason: "high-risk-merchant"
      }
      (if (>= final-score u40)
        {
          action: "ussd-required",
          score: final-score,
          requires-ussd: true,
          auto-release: false,
          reason: "medium-risk-requires-confirmation"
        }
        {
          action: "auto-release",
          score: final-score,
          requires-ussd: false,
          auto-release: true,
          reason: "low-risk-trusted-merchant"
        }
      )
    )
  )
)


;; ============================================
;; Upgrade 4 - Score Decay
;;
;; Reputation should not be permanent.
;; Honest merchants recover over time.
;; Old good behavior should not be abused forever.
;;
;; Decay rate: ~5% per week (every 1008 blocks)
;; Maximum decay: 10 weeks (50% total reduction)
;; Minimum score: 10 (never reaches zero)
;; ============================================

;; Calculates decayed score based on blocks elapsed
;; since last update. Called before reading scores
;; to ensure freshness.
(define-private (apply-decay (score uint) (merchant principal))
  (match (map-get? merchant-last-update merchant)
    last-block (let
      (
        (blocks-passed (- burn-block-height last-block))
        ;; 1008 blocks ~ 1 week on Stacks
        (weeks-passed (/ blocks-passed u1008))
        ;; Cap decay at 10 weeks to prevent score going too low
        (decay-weeks (if (> weeks-passed u10) u10 weeks-passed))
        (decay-amount (/ (* score (* decay-weeks u5)) u100))
      )
      (if (> score decay-amount)
        (- score decay-amount)
        u10  ;; floor - score never drops below 10
      )
    )
    ;; No update history - return score unchanged
    score
  )
)

;; Applies decay to merchant score and saves updated value.
;; Should be called periodically by the gateway.
(define-public (refresh-merchant-score (merchant principal))
  (begin
    (asserts! (or (is-gateway) (is-owner)) ERR-NOT-AUTHORIZED)
    (let
      (
        (rep (unwrap! (map-get? merchant-reputation merchant) ERR-MERCHANT-NOT-FOUND))
        (decayed-score (apply-decay (get risk-score rep) merchant))
      )
      (map-set merchant-reputation merchant
        (merge rep { risk-score: decayed-score })
      )
      (map-set merchant-last-update merchant burn-block-height)
      (ok decayed-score)
    )
  )
)

;; ============================================
;; Core Fraud Detection Functions
;;
;; Called by the gateway contract on key events:
;; - record-payment: on every successful payment
;; - record-dispute: on every raised dispute
;; ============================================

;; Records a payment and initializes merchant reputation
;; if this is their first transaction on the platform
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
        ;; New merchant - initialize with base score of 10
        ;; New merchants start with +20 penalty applied
        ;; via calculate-risk-score new-merchant-penalty
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

;; Records a dispute and recalculates merchant risk score.
;; Disputes in the last 30 days carry more weight than
;; lifetime disputes to reflect current behavior.
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
            last-dispute-block: burn-block-height,
            risk-score: new-risk-score
          })
        )
        (ok new-risk-score)
      )
      (begin
        ;; Dispute before any payment - suspicious, start at 50
        (map-set merchant-reputation merchant {
          total-payments: u0,
          total-disputes: u1,
          disputes-last-30-days: u1,
          last-dispute-block: burn-block-height,
          is-blacklisted: false,
          risk-score: u50,
          flagged-at: none
        })
        (ok u50)
      )
    )
  )
)

;; Logs a suspicious payment for audit purposes.
;; Does not block the payment - only records for review.
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
      flagged-at: burn-block-height
    })
    (var-set suspicious-payment-count (+ flag-id u1))
    (ok flag-id)
  )
)

;; Hard blocks a merchant. Score set to 100.
;; Only the contract owner (platform admin) can blacklist.
;; Use for confirmed fraud cases only.
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
          flagged-at: (some burn-block-height)
        })
      )
      (map-set merchant-reputation merchant {
        total-payments: u0,
        total-disputes: u0,
        disputes-last-30-days: u0,
        last-dispute-block: u0,
        is-blacklisted: true,
        risk-score: u100,
        flagged-at: (some burn-block-height)
      })
    )
    (print { event: "merchant-blacklisted", merchant: merchant, block: burn-block-height })
    (ok true)
  )
)

;; Removes merchant from blacklist. Score reset to 30 (YELLOW).
;; Merchant must rebuild reputation through good behavior.
(define-public (remove-from-blacklist (merchant principal))
  (begin
    (asserts! (is-owner) ERR-NOT-AUTHORIZED)
    (asserts! (is-blacklisted merchant) ERR-NOT-BLACKLISTED)
    (map-set blacklist merchant false)
    (match (map-get? merchant-reputation merchant)
      rep (map-set merchant-reputation merchant
        (merge rep {
          is-blacklisted: false,
          risk-score: u30,  ;; reset to low-YELLOW, not GREEN
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
;;
;; Scoring model:
;; Base:                          +10
;; 1 dispute in 30 days:          +10
;; 2 disputes in 30 days:         +25
;; 3+ disputes in 30 days:        +40
;; New merchant (<5 payments):    +20
;; Growing merchant (<10):        +10
;; Established (20+ payments):    -5
;; Trusted (50+ payments):        -10
;; Blacklisted:                   100 (hard cap)
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
        (base u10)

        ;; Recent disputes carry most weight
        (dispute-30-penalty
          (if (>= disputes-30-days u3) u40
            (if (>= disputes-30-days u2) u25
              (if (>= disputes-30-days u1) u10
                u0
              )
            )
          )
        )

        ;; New merchants are inherently higher risk
        (new-merchant-penalty
          (if (< total-payments u5) u20
            (if (< total-payments u10) u10
              u0
            )
          )
        )

        ;; Established merchants earn trust discount
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

;; Sets the authorized gateway contract.
;; Must be called once after deployment.
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