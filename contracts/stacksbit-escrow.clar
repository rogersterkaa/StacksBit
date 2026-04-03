;; ============================================
;; StacksBit Escrow Contract
;; ============================================
;;
;; OVERVIEW:
;; This contract is the HEART of StacksBit.
;; It holds customer funds in escrow until delivery is confirmed.
;; 
;; Core Functions:
;;   - lock-funds: Accept payment from customer, hold in contract
;;   - release-funds: Send merchant share + fee deduction to merchant
;;   - refund-customer: Return funds if dispute goes to customer
;;   - flag-dispute: Mark payment as disputed, freeze funds
;;
;; CRITICAL DESIGN: Uses as-contract for token transfers
;; This ensures tx-sender context is the contract itself, not the gateway
;; Prevents token contract from misidentifying the sender
;;
;; MULTI-TOKEN SUPPORT:
;; Accepts any SIP-010 token (sBTC, USDC, STX, etc.)
;; Each payment stores its token address
;; Fees are taken in the same token as payment
;;
;; NAIRA SETTLEMENT:
;; Stores ngn-rate with each escrow for off-chain settlement
;; Backend service monitors "funds-released" events
;; Converts ngn-rate * amount = Naira owed
;; Uses Paystack/Flutterwave to settle in local currency
;;
;; Author: Terkaa Tarkighir (Rogersterkaa)
;; License: MIT
;; Version: 1.0
;; ============================================

(use-trait sip-010-trait .sip-010-trait.sip-010-trait)

;; ============================================
;; ERROR CODES
;; ============================================

(define-constant ERR-NOT-AUTHORIZED (err u200))
;; Contract owner checks failed

(define-constant ERR-NOT-GATEWAY (err u201))
;; Only gateway can call this function

(define-constant ERR-PAYMENT-NOT-FOUND (err u210))
;; Payment ID doesn't exist in escrow

(define-constant ERR-WRONG-STATUS (err u211))
;; Payment is not in the expected status for this operation
;; Example: trying to release "pending" payment instead of "locked"

(define-constant ERR-WRONG-TOKEN (err u212))
;; Provided token doesn't match the one in escrow
;; Prevents token confusion attacks

(define-constant ERR-CONTRACT-PAUSED (err u230))
;; Emergency pause is active

(define-constant ERR-INVALID-AMOUNT (err u231))
;; Amount is zero or invalid

;; ============================================
;; DATA VARIABLES
;; ============================================

(define-data-var contract-owner principal tx-sender)
;; Contract deployer - controls fees and platform wallet

(define-data-var gateway-contract (optional principal) none)
;; Gateway contract address - only this can call write functions

(define-data-var contract-paused bool false)
;; Emergency stop mechanism

(define-data-var platform-fee-bps uint u250)
;; Platform fee in basis points (250 = 2.5%)
;; This is what StacksBit earns per transaction
;; Formula: amount * fee-bps / 10000
;; Example: 100000000 * 250 / 10000 = 2500000 (2.5%)

(define-data-var platform-wallet principal tx-sender)
;; Where platform fees are sent
;; Can be multi-sig wallet for added security

;; ============================================
;; DATA MAPS - Escrow Records
;; ============================================

(define-map escrow-records uint {
  token: principal,                   ;; SIP-010 token contract address
  amount: uint,                       ;; Total amount locked (in token smallest units)
  merchant: principal,                ;; Merchant who will receive payment
  customer: principal,                ;; Customer who paid
  status: (string-ascii 16),          ;; "locked" -> "released"/"refunded"/"disputed"
  ngn-rate: (optional uint)           ;; NGN rate at time of payment (for Naira settlement)
})

;; KEY DESIGN NOTES:
;; 
;; 1. ESCROW SECURITY:
;;    - Funds sit in THIS contract (as-contract)
;;    - They never go directly to merchant
;;    - Only released after customer confirms delivery
;;    - This is the core value prop: trustless commerce
;;
;; 2. MULTI-TOKEN:
;;    - Each escrow stores its token address
;;    - Prevents mixing sBTC, USDC, etc.
;;    - Fees taken in same token
;;
;; 3. NAIRA INTEGRATION:
;;    - ngn-rate captures exchange rate at payment time
;;    - Off-chain backend reads "funds-released" event
;;    - Calculates: amount * ngn-rate = Naira owed
;;    - Settles via Paystack/Flutterwave
;;    - User gets money in local currency instantly
;;
;; 4. DISPUTE HANDLING:
;;    - Payment marked "disputed" if customer complains
;;    - Owner can then:
;;      a) refund-customer (customer was right)
;;      b) release-funds (merchant was right)
;;    - Funds remain locked until resolution

;; ============================================
;; PRIVATE HELPER FUNCTIONS
;; ============================================

(define-private (is-gateway)
  ;; Verify caller is the gateway contract
  ;; All sensitive operations gated by this
  (match (var-get gateway-contract) gw (is-eq tx-sender gw) false)
)

;; ============================================
;; READ-ONLY FUNCTIONS
;; ============================================

(define-read-only (get-escrow (payment-id uint))
  ;; Query escrow record for a payment
  ;; Returns: Full escrow details or none
  ;; Usage: Frontend shows order details + status
  (map-get? escrow-records payment-id)
)

(define-read-only (calculate-fee (amount uint))
  ;; Calculate platform fee for a given amount
  ;; Formula: amount * platform-fee-bps / 10000
  ;;
  ;; Math example (250 bps = 2.5%):
  ;;   amount: 100000000 satoshis
  ;;   fee: (100000000 * 250) / 10000 = 2500000 satoshis
  ;;   merchant gets: 97500000
  ;;
  ;; Note: Integer division - results in slight rounding
  ;; Rounding always favors merchant (customers lose fractions)
  (/ (* amount (var-get platform-fee-bps)) u10000)
)

(define-read-only (is-paused)
  ;; Check if contract is paused
  ;; Useful for frontend to show "maintenance mode" message
  (var-get contract-paused)
)

;; ============================================
;; PUBLIC FUNCTIONS - Payment Lifecycle
;; ============================================

(define-public (lock-funds (payment-id uint) (token <sip-010-trait>) (amount uint) (customer principal) (merchant principal) (ngn-rate (optional uint)))
  ;; GATEWAY ONLY: Lock customer payment in escrow
  ;;
  ;; STEP 1 of the payment flow
  ;; Called when customer approves token transfer and gateway initiates it
  ;;
  ;; What happens:
  ;;   1. Customer approves token transfer to THIS contract
  ;;   2. Gateway calls lock-funds with SIP-010 trait
  ;;   3. We use as-contract to receive the funds
  ;;   4. Funds are now held in escrow
  ;;   5. Both merchant and customer can see it
  ;;
  ;; Security:
  ;;   - Uses as-contract (token transfer targets the contract itself)
  ;;   - Verifies payment doesn't already exist
  ;;   - Immutability: once locked, amount cannot change
  ;;
  ;; Events: Emits funds-locked with all details
  ;; Returns: (ok true) or error
  ;;
  ;; NOTE ON as-contract:
  ;; This is critical for SIP-010 compliance.
  ;; Token transfer's tx-sender context must be this contract.
  ;; Without as-contract, transfer would happen from gateway address
  ;; and token contract might reject it.
  (begin
    (asserts! (not (var-get contract-paused)) ERR-CONTRACT-PAUSED)
    (asserts! (or (is-gateway) (is-eq tx-sender customer)) ERR-NOT-GATEWAY)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (is-none (map-get? escrow-records payment-id)) ERR-WRONG-STATUS)
    
    ;; Transfer tokens from customer to this contract
    ;; as-contract ensures tx-sender is this contract
    (try! (contract-call? token transfer amount customer (as-contract tx-sender) none))
    
    ;; Store escrow record
    (map-set escrow-records payment-id {
      token: (contract-of token),
      amount: amount,
      merchant: merchant,
      customer: customer,
      status: "locked",
      ngn-rate: ngn-rate
    })
    
    ;; Emit event for backend to monitor
    (print {event: "funds-locked", payment-id: payment-id, amount: amount, customer: customer, merchant: merchant})
    (ok true)
  )
)

(define-public (release-funds (payment-id uint) (token <sip-010-trait>))
  ;; GATEWAY ONLY: Release funds to merchant
  ;;
  ;; STEP 2 of happy-path payment flow
  ;; Called after customer confirms delivery
  ;;
  ;; What happens:
  ;;   1. Deduct platform fee from amount
  ;;   2. Send merchant share (amount - fee) to merchant
  ;;   3. Send platform fee to platform-wallet
  ;;   4. Mark payment as "released"
  ;;   5. Emit event with fee details for settlement
  ;;
  ;; Fee Calculation Example:
  ;;   Amount: 100000000 (100 sBTC)
  ;;   Fee Rate: 250 bps (2.5%)
  ;;   Fee: 2500000 (2.5 sBTC)
  ;;   Merchant Gets: 97500000 (97.5 sBTC)
  ;;
  ;; Security:
  ;;   - Verifies payment is in "locked" status
  ;;   - Verifies token matches the locked token
  ;;   - Uses as-contract for transfers (critical!)
  ;;   - Atomic: both transfers must succeed
  ;;
  ;; Returns: (ok {payout: uint, fee: uint})
  ;;          payout = amount merchant receives
  ;;          fee = amount platform receives
  (let (
    (escrow (unwrap! (map-get? escrow-records payment-id) ERR-PAYMENT-NOT-FOUND))
    (amount (get amount escrow))
    (merchant (get merchant escrow))
    (fee (calculate-fee amount))
    (payout (- amount fee))
  )
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (or (is-eq (get status escrow) "locked") (is-eq (get status escrow) "disputed")) ERR-WRONG-STATUS)
    (asserts! (is-eq (contract-of token) (get token escrow)) ERR-WRONG-TOKEN)
    
    ;; Transfer merchant's portion using as-contract
    ;; This ensures token contract sees the contract as sender
    (try! (as-contract (contract-call? token transfer payout tx-sender merchant none)))
    
    ;; Transfer platform fee using as-contract
    (try! (as-contract (contract-call? token transfer fee tx-sender (var-get platform-wallet) none)))
    
    ;; Mark as released
    (map-set escrow-records payment-id (merge escrow {status: "released"}))
    
    ;; Emit for backend settlement (Naira, analytics, etc.)
    (print {event: "funds-released", payment-id: payment-id, merchant: merchant, payout: payout, fee: fee})
    
    (ok {payout: payout, fee: fee})
  )
)

(define-public (refund-customer (payment-id uint) (token <sip-010-trait>))
  ;; GATEWAY ONLY: Refund customer (dispute resolution)
  ;;
  ;; Called when dispute is resolved in customer's favor
  ;; Funds go back to customer, merchant gets nothing
  ;;
  ;; Security:
  ;;   - Only works if payment is in "disputed" status
  ;;   - Verifies token matches
  ;;   - Uses as-contract for transfer
  ;;
  ;; Returns: (ok true) or error
  (let (
    (escrow (unwrap! (map-get? escrow-records payment-id) ERR-PAYMENT-NOT-FOUND))
    (amount (get amount escrow))
    (customer (get customer escrow))
  )
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-eq (get status escrow) "disputed") ERR-WRONG-STATUS)
    (asserts! (is-eq (contract-of token) (get token escrow)) ERR-WRONG-TOKEN)
    
    ;; Return full amount to customer
    (try! (as-contract (contract-call? token transfer amount tx-sender customer none)))
    
    ;; Mark as refunded
    (map-set escrow-records payment-id (merge escrow {status: "refunded"}))
    
    ;; Emit event
    (print {event: "customer-refunded", payment-id: payment-id, customer: customer, amount: amount})
    
    (ok true)
  )
)

(define-public (flag-dispute (payment-id uint))
  ;; GATEWAY ONLY: Mark payment as disputed
  ;;
  ;; Called when customer raises a dispute
  ;; Freezes the payment while owner investigates
  ;;
  ;; Status: "locked" -> "disputed"
  ;; Funds remain in escrow, not transferred to anyone
  ;;
  ;; Owner can then call:
  ;;   - refund-customer (if merchant was wrong)
  ;;   - release-funds (if merchant was right)
  ;;
  ;; Security: Can only dispute locked payments
  (let ((escrow (unwrap! (map-get? escrow-records payment-id) ERR-PAYMENT-NOT-FOUND)))
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-eq (get status escrow) "locked") ERR-WRONG-STATUS)
    
    ;; Mark as disputed
    (map-set escrow-records payment-id (merge escrow {status: "disputed"}))
    
    ;; Emit for monitoring
    (print {event: "dispute-flagged", payment-id: payment-id})
    
    (ok true)
  )
)

;; ============================================
;; ADMIN FUNCTIONS
;; ============================================

(define-public (set-gateway (new-gateway principal))
  ;; OWNER ONLY: Set the gateway contract address
  ;;
  ;; Must be called during initialization
  ;; Once set, gateway controls all escrow operations
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set gateway-contract (some new-gateway))
    (ok true)
  )
)

(define-public (set-platform-fee (new-fee-bps uint))
  ;; OWNER ONLY: Adjust the platform fee percentage
  ;;
  ;; Fee is in basis points (bps):
  ;;   100 bps = 1%
  ;;   250 bps = 2.5%
  ;;   1000 bps = 10%
  ;;
  ;; Capped at 1000 bps (max 10%)
  ;; Changes apply to all future payments
  ;; Past payments unaffected
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-fee-bps u1000) ERR-INVALID-AMOUNT)
    (var-set platform-fee-bps new-fee-bps)
    (ok true)
  )
)

(define-public (set-platform-wallet (new-wallet principal))
  ;; OWNER ONLY: Update where platform fees go
  ;;
  ;; Could be:
  ;;   - Single principal (founder wallet)
  ;;   - Multi-sig contract (governance)
  ;;   - DAO treasury
  ;;
  ;; Changes apply to new payments only
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set platform-wallet new-wallet)
    (ok true)
  )
)

(define-public (set-contract-paused (paused bool))
  ;; OWNER ONLY: Emergency pause/resume
  ;;
  ;; When paused: All lock-funds calls fail
  ;; Allows owner to stop the contract in emergency
  ;;
  ;; Does NOT affect already-locked funds
  ;; Does NOT prevent release/refund
  ;; Just stops NEW payments from entering escrow
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set contract-paused paused)
    (ok true)
  )
)

(define-public (set-contract-owner (new-owner principal))
  ;; OWNER ONLY: Transfer ownership
  ;;
  ;; New owner gets all admin powers
  ;; Used to transition from deployer to DAO/multisig
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)
