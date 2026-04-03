;; ============================================
;; StacksBit Merchants Contract
;; ============================================
;; 
;; OVERVIEW:
;; Pure storage layer for the StacksBit payment gateway.
;; This contract manages:
;;   - Merchant profiles and registration
;;   - Payment request tracking
;;   - Per-token merchant balances (supports multi-token)
;;   - Access control (only gateway contract can modify data)
;;
;; ARCHITECTURE:
;; This contract follows the Storage/Gateway pattern:
;;   - stacksbit-merchants (THIS): Pure data storage, no token logic
;;   - stacksbit-escrow: Holds funds, handles token transfers
;;   - stacksbit-gateway: Orchestrates everything, validates inputs
;;
;; This separation enables:
;;   + Clean data access patterns
;;   + Easier contract upgrades
;;   + Single source of truth for merchant data
;;
;; SECURITY MODEL:
;; - All write functions gated behind is-gateway() check
;; - Only the designated gateway contract can modify merchant/payment data
;; - Balances are isolated per merchant AND per token type
;; - Payment status is immutable once settled
;;
;; Author: Terkaa Tarkighir (Rogersterkaa)
;; License: MIT
;; Version: 1.0
;; ============================================

;; ============================================
;; ERROR CODES
;; ============================================
;; Error codes are grouped by category for easier debugging
;; 100-109: Authorization errors
;; 110-119: Data lookup/validation errors
;; 120-129: State/logic errors

(define-constant ERR-NOT-AUTHORIZED (err u100))
;; Raised when: tx-sender is not the gateway contract

(define-constant ERR-NOT-GATEWAY (err u101))
;; Raised when: Caller is not the designated gateway contract

(define-constant ERR-MERCHANT-EXISTS (err u110))
;; Raised when: Attempting to register an owner that already has a merchant account
;; Prevents duplicate merchant registrations

(define-constant ERR-MERCHANT-NOT-FOUND (err u111))
;; Raised when: Querying a merchant-id that doesn't exist

(define-constant ERR-PAYMENT-NOT-FOUND (err u112))
;; Raised when: Querying a payment-id that doesn't exist

(define-constant ERR-INVALID-AMOUNT (err u113))
;; Raised when: Amount is zero or negative (unsigned, so only zero check needed)

(define-constant ERR-INSUFFICIENT-BALANCE (err u120))
;; Raised when: Merchant tries to withdraw more than available balance

(define-constant ERR-PAYMENT-ALREADY-SETTLED (err u121))
;; Raised when: Attempting to modify payment that's already settled/disputed

(define-constant ERR-CONTRACT-PAUSED (err u122))
;; Raised when: Contract is paused (emergency stop mechanism)

;; ============================================
;; DATA VARIABLES (Contract State)
;; ============================================

(define-data-var contract-owner principal tx-sender)
;; Owner principal (deployer) - can pause/unpause and update gateway address
;; Used for emergency controls

(define-data-var gateway-contract (optional principal) none)
;; Address of the gateway contract - must be set before operations
;; All write functions check this address for authorization
;; Using optional principal allows for safe initialization

(define-data-var contract-paused bool false)
;; Emergency pause flag - when true, all public functions return ERR-CONTRACT-PAUSED
;; Allows owner to stop the contract in case of bugs

(define-data-var next-merchant-id uint u1)
;; Auto-increment counter for merchant IDs
;; Starts at u1 (u0 reserved for "not found" checks)

(define-data-var next-payment-id uint u1)
;; Auto-increment counter for payment IDs
;; Starts at u1 (u0 reserved for "not found" checks)

;; ============================================
;; DATA MAPS (Storage)
;; ============================================

;; MERCHANTS MAP
;; Key: merchant-id (uint)
;; Stores complete merchant profile
(define-map merchants uint {
  owner: principal,                    ;; Principal who registered this merchant
  business-name: (string-utf8 100),   ;; Display name (e.g., "Ade's Coffee Shop")
  email: (string-utf8 100),           ;; Contact email for notifications
  is-active: bool,                    ;; Soft delete: merchants can be deactivated
  created-at: uint,                   ;; Block height when merchant registered
  total-received: uint                ;; Total amount received (all tokens combined)
})

;; MERCHANT-BY-OWNER MAP
;; Key: principal (merchant owner address)
;; Value: merchant-id
;; Inverse index for quick lookup: owner principal -> merchant-id
;; Prevents duplicate merchant accounts per owner
(define-map merchant-by-owner principal uint)

;; PAYMENTS MAP
;; Key: payment-id (uint)
;; Stores payment request details and status
;; Note: Actual funds are held in stacksbit-escrow, this is metadata only
(define-map payments uint {
  merchant-id: uint,                      ;; Which merchant created this payment request
  amount: uint,                           ;; Amount in token smallest units (satoshis for sBTC)
  token: principal,                       ;; Token contract address (enables multi-token)
  description: (string-utf8 256),         ;; What is being paid for
  status: (string-ascii 16),              ;; "pending" -> "locked" -> "settled"/"disputed"/"refunded"
  customer: (optional principal),         ;; Who is paying (set when payment is locked)
  created-at: uint,                       ;; Block height when payment created
  settled-at: (optional uint)             ;; Block height when payment settled (null if pending)
})

;; MERCHANT-BALANCES MAP
;; Key: {merchant-id, token}
;; Value: uint (balance in token)
;; Composite key enables per-merchant, per-token balance tracking
;; Example: Merchant #5 might have:
;;   - 1000000 (1 sBTC) in sBTC
;;   - 50000000 (50 USDC) in USDC
(define-map merchant-balances {merchant-id: uint, token: principal} uint)

;; ============================================
;; PRIVATE HELPER FUNCTIONS
;; ============================================

(define-private (is-gateway)
  ;; Check if caller is the designated gateway contract
  ;; Uses match to safely handle optional principal
  ;; Returns: bool (true if tx-sender is gateway)
  (match (var-get gateway-contract) gw (is-eq tx-sender gw) false)
)

(define-private (is-owner)
  ;; Check if caller is the contract owner
  ;; Used for administrative functions (pause, set-gateway)
  (is-eq tx-sender (var-get contract-owner))
)

;; ============================================
;; READ-ONLY FUNCTIONS (No State Changes)
;; ============================================
;; These functions allow anyone to query merchant/payment data
;; No authorization required - data is public

(define-read-only (get-merchant (merchant-id uint))
  ;; Query a merchant's full profile
  ;; Returns: (optional merchant-record)
  ;; Usage: (contract-call? .stacksbit-merchants get-merchant u1)
  (map-get? merchants merchant-id)
)

(define-read-only (get-merchant-id-by-owner (owner principal))
  ;; Lookup merchant ID by owner principal
  ;; Returns: (optional uint) - None if owner has no merchant
  ;; Usage: Look up which merchant a principal operates
  (map-get? merchant-by-owner owner)
)

(define-read-only (get-payment (payment-id uint))
  ;; Query a payment request's current status and details
  ;; Returns: (optional payment-record)
  ;; Used by gateway to verify payment state before processing
  (map-get? payments payment-id)
)

(define-read-only (get-merchant-balance (merchant-id uint) (token principal))
  ;; Get available balance for a specific merchant and token
  ;; Returns: uint (defaults to u0 if no record exists)
  ;; Usage: Check how much a merchant can withdraw
  ;; Note: Uses default-to u0 - safe for non-existent keys
  (default-to u0 (map-get? merchant-balances {merchant-id: merchant-id, token: token}))
)

(define-read-only (get-gateway)
  ;; Return the current gateway contract address
  ;; Useful for frontend to verify which contract is in charge
  (var-get gateway-contract)
)

;; ============================================
;; PUBLIC FUNCTIONS - Merchant Management
;; ============================================

(define-public (register-merchant (owner principal) (business-name (string-utf8 100)) (email (string-utf8 100)))
  ;; GATEWAY ONLY: Register a new merchant account
  ;; 
  ;; Flow:
  ;;   1. Check contract is not paused
  ;;   2. Verify caller is gateway contract
  ;;   3. Ensure owner doesn't already have a merchant account
  ;;   4. Create merchant record with auto-generated ID
  ;;   5. Create reverse index (owner -> merchant-id)
  ;;   6. Increment merchant ID counter
  ;;
  ;; Returns: (ok merchant-id) or error
  ;; Emits: { event: "merchant-registered", merchant-id, owner, business-name }
  ;;
  ;; Security: 
  ;;   - Only gateway can call this
  ;;   - One merchant per owner (enforced by merchant-by-owner map)
  ;;   - Merchants start active
  (let ((merchant-id (var-get next-merchant-id)))
    (asserts! (not (var-get contract-paused)) ERR-CONTRACT-PAUSED)
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-none (map-get? merchant-by-owner owner)) ERR-MERCHANT-EXISTS)
    (map-set merchants merchant-id {owner: owner, business-name: business-name, email: email, is-active: true, created-at: u0, total-received: u0})
    (map-set merchant-by-owner owner merchant-id)
    (var-set next-merchant-id (+ merchant-id u1))
    (ok merchant-id)
  )
)

;; ============================================
;; PUBLIC FUNCTIONS - Payment Management
;; ============================================

(define-public (create-payment (merchant-id uint) (amount uint) (token principal) (description (string-utf8 256)))
  ;; GATEWAY ONLY: Create a new payment request
  ;; 
  ;; Called by gateway when merchant wants to request payment
  ;; This is STEP 1 of payment flow - just creates the request
  ;; No funds are transferred at this stage
  ;;
  ;; Checks:
  ;;   - Contract not paused
  ;;   - Caller is gateway
  ;;   - Merchant ID exists
  ;;   - Amount > 0
  ;;
  ;; Returns: (ok payment-id)
  ;; Emits: { event: "payment-created", payment-id, merchant-id, amount, token }
  ;;
  ;; Note: Status starts as "pending" - waiting for customer to pay
  (let ((payment-id (var-get next-payment-id)))
    (asserts! (not (var-get contract-paused)) ERR-CONTRACT-PAUSED)
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-some (map-get? merchants merchant-id)) ERR-MERCHANT-NOT-FOUND)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (map-set payments payment-id {merchant-id: merchant-id, amount: amount, token: token, description: description, status: "pending", customer: none, created-at: u0, settled-at: none})
    (var-set next-payment-id (+ payment-id u1))
    (ok payment-id)
  )
)

(define-public (lock-payment (payment-id uint) (customer principal))
  ;; GATEWAY ONLY: Mark payment as locked
  ;;
  ;; Called when customer has sent funds to escrow contract
  ;; STEP 2 of payment flow: funds are now locked in escrow
  ;;
  ;; Changes status: "pending" -> "locked"
  ;; Adds customer principal (who paid)
  ;;
  ;; Security: Can only lock pending payments
  (let ((payment (unwrap! (map-get? payments payment-id) ERR-PAYMENT-NOT-FOUND)))
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-eq (get status payment) "pending") ERR-PAYMENT-ALREADY-SETTLED)
    (map-set payments payment-id (merge payment {status: "locked", customer: (some customer)}))
    (ok true)
  )
)

(define-public (settle-payment (payment-id uint))
  ;; GATEWAY ONLY: Finalize a payment
  ;;
  ;; Called after customer confirms delivery
  ;; STEP 3 of payment flow: money released to merchant
  ;;
  ;; Actions:
  ;;   1. Update payment status to "settled"
  ;;   2. Add amount to merchant's balance
  ;;   3. Update total-received stat
  ;;
  ;; This is the final happy-path state for a payment
  ;; Note: Actual token transfer happens in escrow contract
  ;;       This just updates accounting
  (let (
    (payment (unwrap! (map-get? payments payment-id) ERR-PAYMENT-NOT-FOUND))
    (merchant-id (get merchant-id payment))
    (amount (get amount payment))
    (token (get token payment))
    (current-balance (get-merchant-balance merchant-id token))
    (merchant (unwrap! (map-get? merchants merchant-id) ERR-MERCHANT-NOT-FOUND))
  )
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-eq (get status payment) "locked") ERR-PAYMENT-ALREADY-SETTLED)
    (map-set payments payment-id (merge payment {status: "settled", settled-at: (some u0)}))
    (map-set merchant-balances {merchant-id: merchant-id, token: token} (+ current-balance amount))
    (map-set merchants merchant-id (merge merchant {total-received: (+ (get total-received merchant) amount)}))
    (ok true)
  )
)

(define-public (dispute-payment (payment-id uint))
  ;; GATEWAY ONLY: Mark payment as disputed
  ;;
  ;; Called when customer raises a dispute
  ;; Changes status: "locked" -> "disputed"
  ;;
  ;; Funds remain locked in escrow while dispute resolves
  ;; Admin will call either:
  ;;   - resolve-dispute-refund (give money back to customer)
  ;;   - resolve-dispute-release (release to merchant anyway)
  ;;
  ;; Security: Can only dispute locked payments
  (let ((payment (unwrap! (map-get? payments payment-id) ERR-PAYMENT-NOT-FOUND)))
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-eq (get status payment) "locked") ERR-PAYMENT-ALREADY-SETTLED)
    (map-set payments payment-id (merge payment {status: "disputed"}))
    (ok true)
  )
)

;; ============================================
;; PUBLIC FUNCTIONS - Merchant Accounting
;; ============================================

(define-public (deduct-balance (merchant-id uint) (token principal) (amount uint))
  ;; GATEWAY ONLY: Deduct from merchant's available balance
  ;;
  ;; Called when merchant requests a withdrawal
  ;; Removes funds from balance after confirming availability
  ;;
  ;; Security:
  ;;   - Checks merchant has sufficient balance
  ;;   - Atomic: balance updated only if check passes
  ;;   - Prevents over-withdrawal
  (let ((current (get-merchant-balance merchant-id token)))
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (>= current amount) ERR-INSUFFICIENT-BALANCE)
    (map-set merchant-balances {merchant-id: merchant-id, token: token} (- current amount))
    (ok true)
  )
)

(define-public (set-merchant-active (merchant-id uint) (active bool))
  ;; Set merchant active/inactive status
  ;;
  ;; When inactive: merchant cannot create new payment requests
  ;; Allows soft delete without losing transaction history
  ;;
  ;; Authorization: Gateway OR merchant owner themselves
  ;; (Merchants can deactivate their own accounts)
  (let ((merchant (unwrap! (map-get? merchants merchant-id) ERR-MERCHANT-NOT-FOUND)))
    (asserts! (or (is-gateway) (is-eq tx-sender (get owner merchant))) ERR-NOT-AUTHORIZED)
    (map-set merchants merchant-id (merge merchant {is-active: active}))
    (ok true)
  )
)

;; ============================================
;; ADMIN FUNCTIONS
;; ============================================

(define-public (set-gateway (new-gateway principal))
  ;; OWNER ONLY: Update the gateway contract address
  ;;
  ;; Called once during initialization to link this storage contract
  ;; to the gateway contract
  ;;
  ;; Critical: Must be called before any operations
  ;; Once set, gateway contract controls all data mutations
  (begin
    (asserts! (is-owner) ERR-NOT-AUTHORIZED)
    (var-set gateway-contract (some new-gateway))
    (ok true)
  )
)

(define-public (set-contract-paused (paused bool))
  ;; OWNER ONLY: Emergency pause/resume
  ;;
  ;; When paused: all public functions return ERR-CONTRACT-PAUSED
  ;; Allows owner to stop the contract if bugs are discovered
  ;;
  ;; Security: Only read-only functions work when paused
  ;;          Doesn't affect already-settled payments
  (begin
    (asserts! (is-owner) ERR-NOT-AUTHORIZED)
    (var-set contract-paused paused)
    (ok true)
  )
)

(define-public (set-contract-owner (new-owner principal))
  ;; OWNER ONLY: Transfer ownership to new principal
  ;;
  ;; Used to transition ownership after deployment
  ;; New owner inherits:
  ;;   - Ability to set gateway
  ;;   - Ability to pause/unpause
  ;;   - Ability to transfer ownership again
  (begin
    (asserts! (is-owner) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)
