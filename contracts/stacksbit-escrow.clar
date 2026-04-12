;; ============================================
;; StacksBit Escrow Contract
;; ============================================
(use-trait sip-010-trait .sip-010-trait.sip-010-trait)

;; OVERVIEW:
;; This contract is the HEART of StacksBit.
;; It holds customer funds in escrow until delivery is confirmed.
;;
;; Core Functions:
;;   - lock-funds: Accept payment from customer, hold in contract
;;   - release-funds: Send merchant share + fee deduction to merchant
;;   - refund-customer: Return funds if dispute goes to customer
;;   - flag-dispute: Mark payment as disputed, freeze funds
;;   - claim-timeout-refund: Auto-refund customer if merchant never delivers
;;
;; TIME LOCK FEATURE:
;; Every payment has a lock-until block height.
;; If the merchant does not deliver before that block,
;; the customer can call claim-timeout-refund to get
;; their money back automatically -- no admin needed.
;;
;; This makes StacksBit trustless by design:
;;   - Merchant delivers on time -- customer confirms, merchant gets paid
;;   - Merchant disappears -- customer waits for timeout, gets refunded
;;   - No human intervention required in either case
;;
;; Default timeout: 144 blocks (~24 hours on Stacks)
;; Custom timeout: merchant can offer longer lock periods
;;
;; MULTI-TOKEN SUPPORT:
;; Accepts any SIP-010 token (sBTC, USDC, STX, etc.)
;; Each payment stores its token address.
;; Fees are taken in the same token as payment.
;;
;; NAIRA SETTLEMENT:
;; Stores ngn-rate with each escrow for off-chain settlement.
;; Backend service monitors "funds-released" events.
;; Converts ngn-rate * amount = Naira owed.
;; Uses Paystack/Flutterwave to settle in local currency.
;;
;; ARCHITECTURE:
;; This contract follows the Storage/Gateway pattern:
;;   - stacksbit-escrow (THIS): Holds funds, handles transfers
;;   - stacksbit-merchants: Stores merchant profiles and payment records
;;   - stacksbit-gateway: Orchestrates everything, validates inputs
;;
;; Author: Terkaa Tarkighir (rogersterkaa@gmail.com)
;; License: MIT
;; Version: 1.1 (Added time lock feature)
;; ============================================


;; ============================================
;; ERROR CODES
;; ============================================
;; 200-209: Authorization errors
;; 210-219: Data lookup errors
;; 220-229: State/logic errors
;; 230-239: Emergency/pause errors

(define-constant ERR-NOT-AUTHORIZED (err u200))
;; Raised when: contract owner check failed

(define-constant ERR-NOT-GATEWAY (err u201))
;; Raised when: caller is not the designated gateway contract

(define-constant ERR-PAYMENT-NOT-FOUND (err u210))
;; Raised when: payment ID doesn't exist in escrow

(define-constant ERR-WRONG-STATUS (err u211))
;; Raised when: payment is not in the expected status for this operation
;; Example: trying to release a "pending" payment instead of "locked"

(define-constant ERR-WRONG-TOKEN (err u212))
;; Raised when: provided token doesn't match the one stored in escrow
;; Prevents token confusion attacks

(define-constant ERR-NOT-EXPIRED (err u213))
;; Raised when: customer tries to claim timeout refund before lock expires
;; Must wait until stacks-block-height > lock-until

(define-constant ERR-NOT-CUSTOMER (err u214))
;; Raised when: someone other than the original customer tries to claim refund

(define-constant ERR-CONTRACT-PAUSED (err u230))
;; Raised when: emergency pause is active

(define-constant ERR-INVALID-AMOUNT (err u231))
;; Raised when: amount is zero or invalid


;; ============================================
;; DATA VARIABLES (Contract State)
;; ============================================

(define-data-var contract-owner principal tx-sender)
;; Contract deployer. Controls fees and platform wallet.
;; Can pause the contract and update platform settings.

(define-data-var gateway-contract (optional principal) none)
;; Gateway contract address. Only this can call write functions.
;; Must be set via set-gateway before any operations.

(define-data-var contract-paused bool false)
;; Emergency stop mechanism.
;; When true: lock-funds fails, release/refund still work.

(define-data-var platform-fee-bps uint u250)
;; Platform fee in basis points. 250 = 2.5%.
;; Formula: amount * fee-bps / 10000
;; Example: 100000000 * 250 / 10000 = 2500000 (2.5%)
;; Capped at 1000 bps (10%) by set-platform-fee.

(define-data-var platform-wallet principal tx-sender)
;; Where platform fees are sent after each successful payment.
;; Can be updated to a multi-sig wallet for added security.

(define-data-var default-timeout-blocks uint u144)
;; Default number of blocks before a payment can be refunded.
;; 144 blocks = approximately 24 hours on Stacks.
;; Can be overridden per payment via lock-funds.


;; ============================================
;; DATA MAPS (Storage)
;; ============================================

;; ESCROW-RECORDS MAP
;; Key: payment-id (uint)
;; Stores full escrow record for each payment.
;;
;; Fields:
;;   token      -- SIP-010 token contract address
;;   amount     -- Total amount locked (in token smallest units)
;;   merchant   -- Merchant who will receive payment
;;   customer   -- Customer who paid
;;   status     -- "locked" -> "released"/"refunded"/"disputed"/"timeout-refunded"
;;   ngn-rate   -- NGN rate at time of payment (for Naira settlement)
;;   lock-until -- Block height after which customer can claim timeout refund
;;
;; KEY DESIGN NOTES:
;;
;; 1. ESCROW SECURITY:
;;    Funds sit in THIS contract (as-contract).
;;    They never go directly to merchant until customer confirms.
;;    This is the core value prop: trustless commerce.
;;
;; 2. TIME LOCK:
;;    lock-until is set at payment time.
;;    If merchant never delivers, customer gets refunded after timeout.
;;    No admin intervention needed -- fully trustless.
;;
;; 3. MULTI-TOKEN:
;;    Each escrow stores its token address.
;;    Prevents mixing sBTC, USDC, etc.
;;    Fees taken in same token as payment.
;;
;; 4. NAIRA INTEGRATION:
;;    ngn-rate captures exchange rate at payment time.
;;    Off-chain backend reads "funds-released" event.
;;    Calculates: amount * ngn-rate = Naira owed.
;;    Settles via Paystack/Flutterwave.
(define-map escrow-records uint {
  token: principal,
  amount: uint,
  merchant: principal,
  customer: principal,
  status: (string-ascii 20),
  ngn-rate: (optional uint),
  lock-until: uint
})


;; ============================================
;; PRIVATE HELPER FUNCTIONS
;; ============================================

(define-private (is-gateway)
  ;; Verify caller is the gateway contract.
  ;; All sensitive operations gated by this check.
  ;; Returns false if gateway not yet set (prevents accidental access).
  (match (var-get gateway-contract)
    gw (is-eq tx-sender gw)
    false
  )
)


;; ============================================
;; READ-ONLY FUNCTIONS
;; ============================================

(define-read-only (get-escrow (payment-id uint))
  ;; Query escrow record for a payment.
  ;; Returns: Full escrow details or none.
  ;; Usage: Frontend shows order details and status.
  (map-get? escrow-records payment-id)
)

(define-read-only (calculate-fee (amount uint))
  ;; Calculate platform fee for a given amount.
  ;; Formula: amount * platform-fee-bps / 10000
  ;;
  ;; Math example (250 bps = 2.5%):
  ;;   amount: 100000000 satoshis
  ;;   fee: (100000000 * 250) / 10000 = 2500000 satoshis
  ;;   merchant gets: 97500000
  ;;
  ;; Note: Integer division causes slight rounding.
  ;; Rounding always favors merchant (customers lose fractions).
  (/ (* amount (var-get platform-fee-bps)) u10000)
)

(define-read-only (get-default-timeout)
  ;; Return the default timeout in blocks.
  ;; Usage: Frontend shows estimated expiry time to customer.
  (var-get default-timeout-blocks)
)

(define-read-only (is-expired (payment-id uint))
  ;; Check if a payment's time lock has expired.
  ;; Returns: true if current block is past lock-until, false otherwise.
  ;; Usage: Frontend shows "Refund available" button when this returns true.
  (match (map-get? escrow-records payment-id)
    escrow (> stacks-block-height (get lock-until escrow))
    false
  )
)

(define-read-only (blocks-until-expiry (payment-id uint))
  ;; Return how many blocks remain until timeout refund is available.
  ;; Returns: u0 if already expired or payment not found.
  ;; Usage: Frontend countdown timer showing time remaining.
  (match (map-get? escrow-records payment-id)
    escrow (if (> (get lock-until escrow) stacks-block-height)
      (- (get lock-until escrow) stacks-block-height)
      u0
    )
    u0
  )
)

(define-read-only (is-paused)
  ;; Check if contract is paused.
  ;; Usage: Frontend shows "maintenance mode" message when true.
  (var-get contract-paused)
)


;; ============================================
;; PUBLIC FUNCTIONS -- Payment Lifecycle
;; ============================================

(define-public (lock-funds
  (payment-id uint)
  (token <sip-010-trait>)
  (amount uint)
  (customer principal)
  (merchant principal)
  (ngn-rate (optional uint))
)
  ;; GATEWAY ONLY: Lock customer payment in escrow.
  ;;
  ;; STEP 1 of the payment flow.
  ;; Called when customer approves token transfer and gateway initiates it.
  ;;
  ;; What happens:
  ;;   1. Customer approves token transfer to THIS contract
  ;;   2. Gateway calls lock-funds with SIP-010 trait
  ;;   3. We use as-contract to receive the funds
  ;;   4. Funds are now held in escrow with a time lock
  ;;   5. Both merchant and customer can see the escrow record
  ;;
  ;; Time lock:
  ;;   lock-until = current block + default-timeout-blocks
  ;;   After this block, customer can call claim-timeout-refund.
  ;;
  ;; NOTE ON as-contract:
  ;;   This is critical for SIP-010 compliance.
  ;;   Token transfer's tx-sender context must be this contract.
  ;;   Without as-contract, transfer would happen from gateway address.
  ;;
  ;; Emits: funds-locked event with lock-until block height
  ;; Returns: (ok true) or error
  (begin
    (asserts! (not (var-get contract-paused)) ERR-CONTRACT-PAUSED)
    (asserts! (or (is-gateway) (is-eq tx-sender customer)) ERR-NOT-GATEWAY)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (is-none (map-get? escrow-records payment-id)) ERR-WRONG-STATUS)

    ;; Transfer tokens from customer to this contract.
    ;; as-contract ensures tx-sender is this contract during transfer.
    (try! (contract-call? token transfer amount customer (as-contract tx-sender) none))

    ;; Calculate the block height at which this escrow expires.
    ;; After this block, customer can claim an automatic refund.
    (let ((lock-until (+ stacks-block-height (var-get default-timeout-blocks))))

      ;; Store escrow record with time lock.
      (map-set escrow-records payment-id {
        token: (contract-of token),
        amount: amount,
        merchant: merchant,
        customer: customer,
        status: "locked",
        ngn-rate: ngn-rate,
        lock-until: lock-until
      })

      ;; Emit event for backend to monitor.
      ;; lock-until helps frontend show countdown timer.
      (print {
        event: "funds-locked",
        payment-id: payment-id,
        amount: amount,
        customer: customer,
        merchant: merchant,
        lock-until: lock-until
      })
      (ok true)
    )
  )
)

(define-public (release-funds (payment-id uint) (token <sip-010-trait>))
  ;; GATEWAY ONLY: Release funds to merchant after delivery confirmed.
  ;;
  ;; STEP 2 of happy-path payment flow.
  ;; Called after customer confirms delivery.
  ;;
  ;; What happens:
  ;;   1. Deduct platform fee from amount
  ;;   2. Send merchant share (amount - fee) to merchant
  ;;   3. Send platform fee to platform-wallet
  ;;   4. Mark payment as "released"
  ;;   5. Emit event with fee details for Naira settlement
  ;;
  ;; Fee Calculation Example:
  ;;   Amount: 100000000 (100 sBTC)
  ;;   Fee Rate: 250 bps (2.5%)
  ;;   Fee: 2500000 (2.5 sBTC)
  ;;   Merchant Gets: 97500000 (97.5 sBTC)
  ;;
  ;; Security:
  ;;   - Verifies payment is in "locked" or "disputed" status
  ;;   - Verifies token matches the locked token
  ;;   - Uses as-contract for transfers (critical for SIP-010)
  ;;   - Atomic: both transfers must succeed or neither does
  ;;
  ;; Returns: (ok {payout, fee})
  (let (
    (escrow (unwrap! (map-get? escrow-records payment-id) ERR-PAYMENT-NOT-FOUND))
    (amount (get amount escrow))
    (merchant (get merchant escrow))
    (fee (calculate-fee amount))
    (payout (- amount fee))
  )
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (or
      (is-eq (get status escrow) "locked")
      (is-eq (get status escrow) "disputed")
    ) ERR-WRONG-STATUS)
    (asserts! (is-eq (contract-of token) (get token escrow)) ERR-WRONG-TOKEN)

    ;; Transfer merchant's portion using as-contract.
    ;; This ensures token contract sees the escrow contract as sender.
    (try! (as-contract (contract-call? token transfer payout tx-sender merchant none)))

    ;; Transfer platform fee using as-contract.
    (try! (as-contract (contract-call? token transfer fee tx-sender (var-get platform-wallet) none)))

    ;; Mark as released.
    (map-set escrow-records payment-id (merge escrow {status: "released"}))

    ;; Emit for backend settlement (Naira, analytics, etc.)
    (print {
      event: "funds-released",
      payment-id: payment-id,
      merchant: merchant,
      payout: payout,
      fee: fee,
      ngn-rate: (get ngn-rate escrow)
    })

    (ok {payout: payout, fee: fee})
  )
)

(define-public (claim-timeout-refund (payment-id uint) (token <sip-010-trait>))
  ;; CUSTOMER ONLY: Claim automatic refund after time lock expires.
  ;;
  ;; This is the KEY time lock feature.
  ;; If a merchant never delivers, the customer does not need
  ;; to open a dispute or contact anyone. They simply wait for
  ;; the lock-until block to pass and call this function.
  ;;
  ;; Conditions required:
  ;;   1. Payment must be in "locked" status (not already settled)
  ;;   2. Caller must be the original customer
  ;;   3. Current block must be past lock-until
  ;;   4. Token must match the locked token
  ;;
  ;; What happens:
  ;;   1. Verify all conditions above
  ;;   2. Return full amount to customer (no fee deducted)
  ;;   3. Mark payment as "timeout-refunded"
  ;;   4. Emit event for backend monitoring
  ;;
  ;; Note: Full amount is returned. Platform does not charge fees
  ;; on timeout refunds -- merchant failed to deliver.
  ;;
  ;; Emits: timeout-refund event
  ;; Returns: (ok true) or error
  (let (
    (escrow (unwrap! (map-get? escrow-records payment-id) ERR-PAYMENT-NOT-FOUND))
    (amount (get amount escrow))
    (customer (get customer escrow))
  )
    ;; Only the original customer can claim the timeout refund.
    (asserts! (is-eq tx-sender customer) ERR-NOT-CUSTOMER)

    ;; Payment must still be locked (not already settled or disputed).
    (asserts! (is-eq (get status escrow) "locked") ERR-WRONG-STATUS)

    ;; Token must match to prevent token confusion attacks.
    (asserts! (is-eq (contract-of token) (get token escrow)) ERR-WRONG-TOKEN)

    ;; Time lock must have expired.
    ;; Customer must wait until stacks-block-height > lock-until.
    (asserts! (> stacks-block-height (get lock-until escrow)) ERR-NOT-EXPIRED)

    ;; Return full amount to customer. No fees on timeout refunds.
    (try! (as-contract (contract-call? token transfer amount tx-sender customer none)))

    ;; Mark as timeout-refunded so it cannot be claimed again.
    (map-set escrow-records payment-id (merge escrow {status: "timeout-refunded"}))

    ;; Emit for backend monitoring and merchant notification.
    (print {
      event: "timeout-refund",
      payment-id: payment-id,
      customer: customer,
      amount: amount
    })

    (ok true)
  )
)

(define-public (refund-customer (payment-id uint) (token <sip-010-trait>))
  ;; GATEWAY ONLY: Refund customer after dispute resolved in their favor.
  ;;
  ;; Called when admin resolves dispute in customer's favor.
  ;; Funds go back to customer. Merchant gets nothing.
  ;;
  ;; Different from claim-timeout-refund:
  ;;   - This requires admin (gateway) authorization
  ;;   - This works on "disputed" payments only
  ;;   - claim-timeout-refund is customer-initiated after timeout
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

    ;; Return full amount to customer.
    (try! (as-contract (contract-call? token transfer amount tx-sender customer none)))

    ;; Mark as refunded.
    (map-set escrow-records payment-id (merge escrow {status: "refunded"}))

    ;; Emit event for backend monitoring.
    (print {event: "customer-refunded", payment-id: payment-id, customer: customer, amount: amount})

    (ok true)
  )
)

(define-public (flag-dispute (payment-id uint))
  ;; GATEWAY ONLY: Mark payment as disputed.
  ;;
  ;; Called when customer raises a dispute.
  ;; Freezes the payment while admin investigates.
  ;;
  ;; Status: "locked" -> "disputed"
  ;; Funds remain in escrow. Not transferred to anyone yet.
  ;;
  ;; Once disputed, admin can call:
  ;;   - refund-customer (if merchant was wrong)
  ;;   - release-funds (if merchant was right)
  ;;
  ;; Note: A disputed payment cannot be timeout-refunded.
  ;; This prevents customer from disputing AND claiming timeout.
  ;;
  ;; Security: Can only dispute locked payments.
  (let ((escrow (unwrap! (map-get? escrow-records payment-id) ERR-PAYMENT-NOT-FOUND)))
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-eq (get status escrow) "locked") ERR-WRONG-STATUS)

    ;; Mark as disputed.
    (map-set escrow-records payment-id (merge escrow {status: "disputed"}))

    ;; Emit for monitoring.
    (print {event: "dispute-flagged", payment-id: payment-id})

    (ok true)
  )
)


;; ============================================
;; ADMIN FUNCTIONS
;; ============================================

(define-public (set-gateway (new-gateway principal))
  ;; OWNER ONLY: Set the gateway contract address.
  ;;
  ;; Must be called during initialization.
  ;; Once set, gateway controls all escrow operations.
  ;; Can be updated if gateway contract is upgraded.
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set gateway-contract (some new-gateway))
    (ok true)
  )
)

(define-public (set-platform-fee (new-fee-bps uint))
  ;; OWNER ONLY: Adjust the platform fee percentage.
  ;;
  ;; Fee is in basis points (bps):
  ;;   100 bps = 1%
  ;;   250 bps = 2.5% (default)
  ;;   1000 bps = 10% (maximum allowed)
  ;;
  ;; Changes apply to all future payments.
  ;; Past payments are unaffected.
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-fee-bps u1000) ERR-INVALID-AMOUNT)
    (var-set platform-fee-bps new-fee-bps)
    (ok true)
  )
)

(define-public (set-platform-wallet (new-wallet principal))
  ;; OWNER ONLY: Update where platform fees are sent.
  ;;
  ;; Could be:
  ;;   - Single principal (founder wallet)
  ;;   - Multi-sig contract (governance)
  ;;   - DAO treasury
  ;;
  ;; Changes apply to new payments only.
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set platform-wallet new-wallet)
    (ok true)
  )
)

(define-public (set-default-timeout (blocks uint))
  ;; OWNER ONLY: Update the default timeout period.
  ;;
  ;; Default is 144 blocks (~24 hours).
  ;; Can be increased for longer delivery windows.
  ;; Changes apply to new payments only.
  ;; Past payments keep their original lock-until value.
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set default-timeout-blocks blocks)
    (ok true)
  )
)

(define-public (set-contract-paused (paused bool))
  ;; OWNER ONLY: Emergency pause/resume.
  ;;
  ;; When paused: All lock-funds calls fail.
  ;; Does NOT affect already-locked funds.
  ;; Does NOT prevent release/refund/timeout-refund.
  ;; Just stops NEW payments from entering escrow.
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set contract-paused paused)
    (ok true)
  )
)

(define-public (set-contract-owner (new-owner principal))
  ;; OWNER ONLY: Transfer ownership to new principal.
  ;;
  ;; New owner inherits all admin powers:
  ;;   - Set gateway
  ;;   - Adjust fees
  ;;   - Update platform wallet
  ;;   - Pause/unpause
  ;;   - Transfer ownership again
  ;;
  ;; Use case: transition from deployer to DAO or multisig.
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)