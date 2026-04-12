;; ============================================
;; StacksBit Fraud Detection + Merchant Reputation Contract
;; ============================================
;;
;; OVERVIEW:
;; This contract is the TRUST LAYER of StacksBit.
;; It tracks merchant behavior over time and produces
;; two scores for every merchant:
;;
;;   - Trust Score (0-100): Higher = more trustworthy
;;     Increases with successful payments
;;     Decreases with disputes and refunds
;;
;;   - Risk Score (0-100): Higher = more dangerous
;;     Increases with disputes and new accounts
;;     Decreases as merchant builds history
;;
;; BADGES:
;;   New     -- fewer than 25 payments
;;   Rising  -- 25 to 99 payments
;;   Trusted -- 100 to 499 payments
;;   Elite   -- 500+ payments, low disputes
;;   Flagged -- blacklisted by admin
;;
;; ARCHITECTURE:
;; This contract is a standalone reputation layer.
;; It does NOT hold funds or process payments.
;; It is called by:
;;   - stacksbit-gateway: to record payment outcomes
;;   - Frontend/API: to read merchant trust scores
;;
;; SCORING PHILOSOPHY:
;; Trust is earned slowly, lost quickly.
;;   - 500 payments = max trust bonus (+60)
;;   - 0 disputes ever = max dispute bonus (+40)
;;   - 3+ disputes in 30 days = high risk flag
;;   - Blacklist = instant 0 trust, 100 risk
;;
;; SECURITY MODEL:
;; - Only gateway or owner can record payment outcomes
;; - Only owner can blacklist/unblacklist merchants
;; - All read functions are public (trust is transparent)
;;
;; Author: Terkaa Tarkighir (rogersterkaa@gmail.com)
;; License: MIT
;; Version: 1.1
;; ============================================


;; ============================================
;; ERROR CODES
;; ============================================
;; 500-509: Authorization errors
;; 510-519: Data lookup errors

(define-constant ERR-NOT-AUTHORIZED (err u500))
;; Raised when: caller is neither gateway nor owner

(define-constant ERR-NOT-GATEWAY (err u501))
;; Raised when: caller is not the designated gateway contract

(define-constant ERR-MERCHANT-NOT-FOUND (err u510))
;; Raised when: querying a merchant with no reputation record

(define-constant ERR-ALREADY-BLACKLISTED (err u511))
;; Raised when: trying to blacklist an already blacklisted merchant

(define-constant ERR-NOT-BLACKLISTED (err u512))
;; Raised when: trying to remove from blacklist a non-blacklisted merchant


;; ============================================
;; REPUTATION BADGES
;; ============================================
;; Badges are stored as uint constants for gas efficiency.
;; Frontend maps these uint values to labels and icons.
;;
;; Badge thresholds (by total successful payments):
;;   BADGE-NEW     -- 0 to 24 payments
;;   BADGE-RISING  -- 25 to 99 payments
;;   BADGE-TRUSTED -- 100 to 499 payments
;;   BADGE-ELITE   -- 500+ payments
;;   BADGE-FLAGGED -- blacklisted (overrides all others)

(define-constant BADGE-NEW u0)
(define-constant BADGE-RISING u1)
(define-constant BADGE-TRUSTED u2)
(define-constant BADGE-ELITE u3)
(define-constant BADGE-FLAGGED u4)


;; ============================================
;; DATA VARIABLES (Contract State)
;; ============================================

(define-data-var contract-owner principal tx-sender)
;; Deployer address. Controls admin functions.
;; Can blacklist merchants and set gateway address.

(define-data-var gateway-contract (optional principal) none)
;; Address of stacksbit-gateway contract.
;; Must be set via set-gateway before operations begin.
;; All write functions (record-payment, record-dispute) require this.


;; ============================================
;; DATA MAPS (Storage)
;; ============================================

;; MERCHANT-REPUTATION MAP
;; Key: principal (merchant's Stacks address)
;; Stores complete reputation profile per merchant.
;;
;; Fields:
;;   total-payments        -- lifetime successful payments (increases trust)
;;   total-disputes        -- lifetime disputes raised against merchant
;;   total-refunds         -- lifetime refunds issued (hurts trust slightly)
;;   disputes-last-30-days -- rolling dispute count (triggers risk flag)
;;   last-dispute-block    -- block height of most recent dispute
;;   is-blacklisted        -- true = merchant is banned from platform
;;   trust-score           -- 0-100, shown to customers as safety indicator
;;   risk-score            -- 0-100, internal fraud signal
;;   badge                 -- uint mapped to New/Rising/Trusted/Elite/Flagged
;;   registered-at         -- block height when reputation was first created
(define-map merchant-reputation principal {
  total-payments: uint,
  total-disputes: uint,
  total-refunds: uint,
  disputes-last-30-days: uint,
  last-dispute-block: uint,
  is-blacklisted: bool,
  trust-score: uint,
  risk-score: uint,
  badge: uint,
  registered-at: uint
})

;; BLACKLIST MAP
;; Key: principal
;; Value: bool (true = blacklisted)
;; Separate from reputation map for fast O(1) blacklist checks.
;; Used at payment entry points to block bad actors instantly.
(define-map blacklist principal bool)

;; SUSPICIOUS-PAYMENTS MAP
;; Key: uint (auto-incrementing flag ID)
;; Stores flagged payment details for admin review.
;; Does NOT block payment -- just records suspicion.
;; Admin can act on flags manually or via future automation.
(define-map suspicious-payments uint {
  payment-id: uint,
  merchant: principal,
  reason: (string-ascii 100),
  flagged-at: uint
})

(define-data-var suspicious-payment-count uint u0)
;; Auto-increment counter for suspicious payment flag IDs.
;; Starts at u0.


;; ============================================
;; PRIVATE HELPER FUNCTIONS
;; ============================================

(define-private (is-gateway)
  ;; Check if the caller is the designated gateway contract.
  ;; Uses match to safely unwrap the optional principal.
  ;; Returns false if gateway is not yet set (prevents accidental access).
  (match (var-get gateway-contract)
    gw (is-eq tx-sender gw)
    false
  )
)

(define-private (is-owner)
  ;; Check if the caller is the contract owner (deployer).
  ;; Used for admin-only functions like blacklisting.
  (is-eq tx-sender (var-get contract-owner))
)


;; ============================================
;; TRUST SCORE CALCULATOR
;; ============================================
;; Trust Score: 0-100 (higher = more trustworthy)
;; This score is shown to CUSTOMERS to help them decide
;; whether to pay a merchant.
;;
;; Formula:
;;   trust = payment_score + dispute_bonus - refund_penalty
;;   Capped at 100, floored at 0.
;;
;; payment_score: rewards merchants who process many orders
;;   500+ payments -- +60 points (max)
;;   100+ payments -- +50 points
;;    25+ payments -- +35 points
;;     5+ payments -- +20 points
;;    <5  payments -- +10 points (baseline)
;;
;; dispute_bonus: rewards merchants with clean history
;;   0 disputes ever -- +40 points (max)
;;   <3 disputes     -- +25 points
;;   <10 disputes    -- +10 points
;;   10+ disputes    --  +0 points
;;
;; refund_penalty: small penalty for refunds (bad service signal)
;;   10+ refunds -- -20 points
;;    5+ refunds -- -10 points
;;    2+ refunds --  -5 points
;;    <2 refunds --   0 points

(define-private (calculate-trust-score
  (total-payments uint)
  (total-disputes uint)
  (total-refunds uint)
  (blacklisted bool)
)
  ;; Blacklisted merchants always get 0 trust. No exceptions.
  (if blacklisted
    u0
    (let (
      ;; Reward payment volume. The more orders processed, the more trusted.
      (payment-score
        (if (>= total-payments u500) u60
          (if (>= total-payments u100) u50
            (if (>= total-payments u25) u35
              (if (>= total-payments u5) u20
                u10
              )
            )
          )
        )
      )

      ;; Reward clean dispute history. Zero disputes is the ideal.
      (dispute-bonus
        (if (is-eq total-disputes u0) u40
          (if (< total-disputes u3) u25
            (if (< total-disputes u10) u10
              u0
            )
          )
        )
      )

      ;; Small penalty for refunds. Signals poor service quality.
      (refund-penalty
        (if (>= total-refunds u10) u20
          (if (>= total-refunds u5) u10
            (if (>= total-refunds u2) u5
              u0
            )
          )
        )
      )

      (raw-score (+ payment-score dispute-bonus))
    )
      ;; Subtract penalty, floor at 0, cap at 100.
      (if (> raw-score refund-penalty)
        (if (> (- raw-score refund-penalty) u100)
          u100
          (- raw-score refund-penalty)
        )
        u0
      )
    )
  )
)


;; ============================================
;; RISK SCORE CALCULATOR
;; ============================================
;; Risk Score: 0-100 (higher = more dangerous)
;; This score is used INTERNALLY for fraud detection.
;; High risk merchants may be flagged for review.
;;
;; Formula:
;;   risk = base + dispute_30_penalty + new_merchant_penalty - established_bonus
;;
;; base: every merchant starts at 10 (no one is perfectly safe by default)
;;
;; dispute_30_penalty: recent disputes are a strong fraud signal
;;   3+ disputes in 30 days -- +40 points (very high risk)
;;   2  disputes in 30 days -- +25 points
;;   1  dispute  in 30 days -- +10 points
;;   0  disputes in 30 days --  +0 points
;;
;; new_merchant_penalty: new accounts are higher risk by default
;;   <5  payments -- +20 points
;;   <10 payments -- +10 points
;;   10+ payments --  +0 points
;;
;; established_bonus: reward long-term merchants with lower risk
;;   50+ payments -- -10 points
;;   20+ payments --  -5 points
;;   <20 payments --   0 points

(define-private (calculate-risk-score
  (total-payments uint)
  (total-disputes uint)
  (disputes-30-days uint)
  (blacklisted bool)
)
  ;; Blacklisted = maximum risk. No calculation needed.
  (if blacklisted
    u100
    (let (
      ;; Every merchant starts with a small baseline risk.
      (base u10)

      ;; Recent disputes in 30 days are the strongest fraud signal.
      ;; 3+ disputes in a month = almost certainly problematic.
      (dispute-30-penalty
        (if (>= disputes-30-days u3) u40
          (if (>= disputes-30-days u2) u25
            (if (>= disputes-30-days u1) u10
              u0
            )
          )
        )
      )

      ;; New merchants are inherently riskier. No track record yet.
      (new-merchant-penalty
        (if (< total-payments u5) u20
          (if (< total-payments u10) u10
            u0
          )
        )
      )

      ;; Long-term merchants with volume earn a small risk reduction.
      (established-bonus
        (if (>= total-payments u50) u10
          (if (>= total-payments u20) u5
            u0
          )
        )
      )

      (raw-score (+ (+ base dispute-30-penalty) new-merchant-penalty))
    )
      ;; Subtract bonus, floor at 0.
      (if (> raw-score established-bonus)
        (- raw-score established-bonus)
        u0
      )
    )
  )
)


;; ============================================
;; BADGE CALCULATOR
;; ============================================
;; Badges are visual trust indicators shown on merchant profiles.
;; They are purely based on total payment volume.
;; A blacklisted merchant always gets BADGE-FLAGGED regardless of volume.

(define-private (calculate-badge
  (total-payments uint)
  (blacklisted bool)
)
  (if blacklisted
    BADGE-FLAGGED
    (if (>= total-payments u500) BADGE-ELITE
      (if (>= total-payments u100) BADGE-TRUSTED
        (if (>= total-payments u25) BADGE-RISING
          BADGE-NEW
        )
      )
    )
  )
)


;; ============================================
;; READ-ONLY FUNCTIONS
;; ============================================
;; These are public. Anyone can query merchant reputation.
;; Transparency is core to the trust model.
;; No authorization required.

(define-read-only (get-merchant-reputation (merchant principal))
  ;; Return the full raw reputation record for a merchant.
  ;; Returns: (optional reputation-record)
  ;; Returns none if merchant has no reputation yet.
  (map-get? merchant-reputation merchant)
)

(define-read-only (get-trust-score (merchant principal))
  ;; Return just the trust score (0-100) for quick checks.
  ;; Returns u0 if merchant has no reputation record.
  ;; Usage: Frontend displays this as the main trust indicator.
  (match (map-get? merchant-reputation merchant)
    rep (get trust-score rep)
    u0
  )
)

(define-read-only (get-risk-score (merchant principal))
  ;; Return just the risk score (0-100) for fraud API.
  ;; Returns u0 if merchant has no reputation record.
  ;; Usage: Fraud API uses this to return green/yellow/red signals.
  (match (map-get? merchant-reputation merchant)
    rep (get risk-score rep)
    u0
  )
)

(define-read-only (get-badge (merchant principal))
  ;; Return badge as uint (0=New, 1=Rising, 2=Trusted, 3=Elite, 4=Flagged).
  ;; Returns BADGE-NEW if merchant has no reputation record.
  (match (map-get? merchant-reputation merchant)
    rep (get badge rep)
    BADGE-NEW
  )
)

(define-read-only (get-badge-name (merchant principal))
  ;; Return badge as human-readable string.
  ;; Usage: Frontend displays this directly on merchant profile.
  ;; Example: "Trusted" or "Elite" or "Flagged"
  (let ((badge (get-badge merchant)))
    (if (is-eq badge BADGE-ELITE) "Elite"
      (if (is-eq badge BADGE-TRUSTED) "Trusted"
        (if (is-eq badge BADGE-RISING) "Rising"
          (if (is-eq badge BADGE-FLAGGED) "Flagged"
            "New"
          )
        )
      )
    )
  )
)

(define-read-only (get-full-profile (merchant principal))
  ;; Return a clean summary object for frontend display.
  ;; Combines trust score, risk score, badge and stats.
  ;; Always returns (ok ...). Uses defaults for new merchants.
  ;;
  ;; Usage: Merchant profile page, payment confirmation screen.
  ;; Example response:
  ;;   { trust-score: u85, badge: "Trusted", total-payments: u120, ... }
  (match (map-get? merchant-reputation merchant)
    rep (ok {
      trust-score: (get trust-score rep),
      risk-score: (get risk-score rep),
      badge: (get-badge-name merchant),
      total-payments: (get total-payments rep),
      total-disputes: (get total-disputes rep),
      total-refunds: (get total-refunds rep),
      is-blacklisted: (get is-blacklisted rep)
    })
    ;; New merchant defaults. Safe to display on frontend.
    (ok {
      trust-score: u0,
      risk-score: u10,
      badge: "New",
      total-payments: u0,
      total-disputes: u0,
      total-refunds: u0,
      is-blacklisted: false
    })
  )
)

(define-read-only (is-blacklisted (address principal))
  ;; Fast blacklist check. O(1) map lookup.
  ;; Returns false by default for unknown addresses.
  ;; Usage: Payment entry point to block bad actors instantly.
  (default-to false (map-get? blacklist address))
)

(define-read-only (is-high-risk (merchant principal))
  ;; Returns true if risk score is 70 or above.
  ;; Usage: Gateway can warn customers before payment.
  (>= (get-risk-score merchant) u70)
)

(define-read-only (is-trusted (merchant principal))
  ;; Returns true if trust score is 70 or above.
  ;; Usage: Frontend shows trust badge on merchant profile.
  (>= (get-trust-score merchant) u70)
)


;; ============================================
;; PUBLIC FUNCTIONS -- Recording Outcomes
;; ============================================
;; These are called by the gateway contract after each event.
;; They update reputation scores automatically.
;; Authorization: gateway OR owner only.

(define-public (record-payment (merchant principal))
  ;; GATEWAY/OWNER ONLY: Record a successful payment.
  ;;
  ;; Called by gateway after: confirm-delivery succeeds.
  ;; Effect: Increases trust score, upgrades badge if threshold reached.
  ;;
  ;; Flow:
  ;;   1. Check caller is gateway or owner.
  ;;   2. If merchant has existing record -- increment and recalculate.
  ;;   3. If new merchant -- initialize with first payment.
  ;;
  ;; Returns: (ok new-trust-score)
  (begin
    (asserts! (or (is-gateway) (is-owner)) ERR-NOT-AUTHORIZED)
    (match (map-get? merchant-reputation merchant)
      rep (let (
        (new-total (+ (get total-payments rep) u1))
        (new-trust (calculate-trust-score new-total (get total-disputes rep) (get total-refunds rep) (get is-blacklisted rep)))
        (new-risk (calculate-risk-score new-total (get total-disputes rep) (get disputes-last-30-days rep) (get is-blacklisted rep)))
        (new-badge (calculate-badge new-total (get is-blacklisted rep)))
      )
        (map-set merchant-reputation merchant
          (merge rep {
            total-payments: new-total,
            trust-score: new-trust,
            risk-score: new-risk,
            badge: new-badge
          })
        )
        (ok new-trust)
      )
      ;; First payment for this merchant. Initialize reputation record.
      (begin
        (map-set merchant-reputation merchant {
          total-payments: u1,
          total-disputes: u0,
          total-refunds: u0,
          disputes-last-30-days: u0,
          last-dispute-block: u0,
          is-blacklisted: false,
          trust-score: u10,
          risk-score: u20,
          badge: BADGE-NEW,
          registered-at: stacks-block-height
        })
        (ok u10)
      )
    )
  )
)

(define-public (record-dispute (merchant principal))
  ;; GATEWAY/OWNER ONLY: Record a dispute raised against merchant.
  ;;
  ;; Called by gateway after: raise-dispute succeeds.
  ;; Effect: Decreases trust score, increases risk score.
  ;;         Updates 30-day dispute counter for rolling fraud detection.
  ;;
  ;; Note: disputes-last-30-days is incremented here but never decremented.
  ;; A future upgrade could add block-height based decay.
  ;;
  ;; Returns: (ok new-risk-score)
  (begin
    (asserts! (or (is-gateway) (is-owner)) ERR-NOT-AUTHORIZED)
    (match (map-get? merchant-reputation merchant)
      rep (let (
        (new-disputes (+ (get total-disputes rep) u1))
        (new-disputes-30 (+ (get disputes-last-30-days rep) u1))
        (new-trust (calculate-trust-score (get total-payments rep) new-disputes (get total-refunds rep) (get is-blacklisted rep)))
        (new-risk (calculate-risk-score (get total-payments rep) new-disputes new-disputes-30 (get is-blacklisted rep)))
      )
        (map-set merchant-reputation merchant
          (merge rep {
            total-disputes: new-disputes,
            disputes-last-30-days: new-disputes-30,
            last-dispute-block: stacks-block-height,
            trust-score: new-trust,
            risk-score: new-risk
          })
        )
        (ok new-risk)
      )
      ;; First interaction is a dispute. Initialize with bad signal.
      (begin
        (map-set merchant-reputation merchant {
          total-payments: u0,
          total-disputes: u1,
          total-refunds: u0,
          disputes-last-30-days: u1,
          last-dispute-block: stacks-block-height,
          is-blacklisted: false,
          trust-score: u0,
          risk-score: u50,
          badge: BADGE-NEW,
          registered-at: stacks-block-height
        })
        (ok u50)
      )
    )
  )
)

(define-public (record-refund (merchant principal))
  ;; GATEWAY/OWNER ONLY: Record a refund issued to a customer.
  ;;
  ;; Called by gateway after: resolve-dispute-refund succeeds.
  ;; Effect: Slightly decreases trust score.
  ;;         Less severe than disputes. Refunds can be legitimate.
  ;;
  ;; Returns: (ok new-trust-score)
  (begin
    (asserts! (or (is-gateway) (is-owner)) ERR-NOT-AUTHORIZED)
    (match (map-get? merchant-reputation merchant)
      rep (let (
        (new-refunds (+ (get total-refunds rep) u1))
        (new-trust (calculate-trust-score (get total-payments rep) (get total-disputes rep) new-refunds (get is-blacklisted rep)))
      )
        (map-set merchant-reputation merchant
          (merge rep {
            total-refunds: new-refunds,
            trust-score: new-trust
          })
        )
        (ok new-trust)
      )
      ;; Merchant has no record. Refund without prior history.
      (ok u0)
    )
  )
)

(define-public (blacklist-merchant (merchant principal))
  ;; OWNER ONLY: Permanently flag a merchant as banned.
  ;;
  ;; Effect:
  ;;   - Sets is-blacklisted: true
  ;;   - Forces trust-score to u0
  ;;   - Forces risk-score to u100
  ;;   - Sets badge to BADGE-FLAGGED
  ;;   - Records in both blacklist map AND reputation map
  ;;
  ;; The dual map design (blacklist + reputation) allows fast O(1)
  ;; blacklist checks at payment entry without loading full reputation.
  ;;
  ;; Emits: { event: "merchant-blacklisted", merchant }
  ;; Returns: (ok true)
  (begin
    (asserts! (is-owner) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-blacklisted merchant)) ERR-ALREADY-BLACKLISTED)
    (map-set blacklist merchant true)
    (match (map-get? merchant-reputation merchant)
      rep (map-set merchant-reputation merchant
        (merge rep {
          is-blacklisted: true,
          trust-score: u0,
          risk-score: u100,
          badge: BADGE-FLAGGED
        })
      )
      ;; Blacklisting merchant with no prior reputation record.
      (map-set merchant-reputation merchant {
        total-payments: u0,
        total-disputes: u0,
        total-refunds: u0,
        disputes-last-30-days: u0,
        last-dispute-block: u0,
        is-blacklisted: true,
        trust-score: u0,
        risk-score: u100,
        badge: BADGE-FLAGGED,
        registered-at: stacks-block-height
      })
    )
    (print { event: "merchant-blacklisted", merchant: merchant })
    (ok true)
  )
)

(define-public (remove-from-blacklist (merchant principal))
  ;; OWNER ONLY: Reinstate a previously blacklisted merchant.
  ;;
  ;; Effect:
  ;;   - Sets is-blacklisted: false
  ;;   - Resets trust to u20 (not zero, gives a fresh start)
  ;;   - Resets risk to u30 (still elevated, not fully trusted yet)
  ;;   - Resets badge to BADGE-NEW
  ;;
  ;; Note: Merchant history (disputes, payments) is preserved.
  ;; They start fresh on badge/score but history remains on-chain.
  ;;
  ;; Emits: { event: "merchant-unblacklisted", merchant }
  ;; Returns: (ok true)
  (begin
    (asserts! (is-owner) ERR-NOT-AUTHORIZED)
    (asserts! (is-blacklisted merchant) ERR-NOT-BLACKLISTED)
    (map-set blacklist merchant false)
    (match (map-get? merchant-reputation merchant)
      rep (map-set merchant-reputation merchant
        (merge rep {
          is-blacklisted: false,
          trust-score: u20,
          risk-score: u30,
          badge: BADGE-NEW
        })
      )
      true
    )
    (print { event: "merchant-unblacklisted", merchant: merchant })
    (ok true)
  )
)

(define-public (flag-suspicious-payment
  (payment-id uint)
  (merchant principal)
  (reason (string-ascii 100))
)
  ;; GATEWAY/OWNER ONLY: Flag a payment as suspicious for review.
  ;;
  ;; This does NOT block the payment. It records a suspicion.
  ;; Admin or automated system reviews flagged payments.
  ;;
  ;; Use cases:
  ;;   - Unusually large payment amount
  ;;   - Merchant with rising risk score
  ;;   - Pattern of rapid sequential payments
  ;;
  ;; Returns: (ok flag-id) -- auto-incremented ID for this flag
  (let ((flag-id (var-get suspicious-payment-count)))
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


;; ============================================
;; ADMIN FUNCTIONS
;; ============================================

(define-public (set-gateway (new-gateway principal))
  ;; OWNER ONLY: Set the gateway contract address.
  ;;
  ;; Must be called once during initialization.
  ;; After this, only the gateway can call record-* functions.
  ;; Can be updated if gateway contract is upgraded.
  (begin
    (asserts! (is-owner) ERR-NOT-AUTHORIZED)
    (var-set gateway-contract (some new-gateway))
    (ok true)
  )
)

(define-public (set-contract-owner (new-owner principal))
  ;; OWNER ONLY: Transfer contract ownership.
  ;;
  ;; New owner inherits:
  ;;   - Ability to set gateway
  ;;   - Ability to blacklist/unblacklist merchants
  ;;   - Ability to transfer ownership again
  ;;
  ;; Use case: transition from founder wallet to multisig or DAO.
  (begin
    (asserts! (is-owner) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)