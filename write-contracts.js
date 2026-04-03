import fs from 'fs';

// ===== MERCHANTS =====
const merchants = `
;; StacksBit Merchants Contract
;; Pure storage layer - merchant registry and payment records
;;
;; Author: Terkaa Tarkighir (Rogersterkaa)
;; License: MIT

(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-NOT-GATEWAY (err u101))
(define-constant ERR-MERCHANT-EXISTS (err u110))
(define-constant ERR-MERCHANT-NOT-FOUND (err u111))
(define-constant ERR-PAYMENT-NOT-FOUND (err u112))
(define-constant ERR-INVALID-AMOUNT (err u113))
(define-constant ERR-INSUFFICIENT-BALANCE (err u120))
(define-constant ERR-PAYMENT-ALREADY-SETTLED (err u121))
(define-constant ERR-CONTRACT-PAUSED (err u122))

(define-data-var contract-owner principal tx-sender)
(define-data-var gateway-contract (optional principal) none)
(define-data-var contract-paused bool false)
(define-data-var next-merchant-id uint u1)
(define-data-var next-payment-id uint u1)

(define-map merchants uint {
  owner: principal,
  business-name: (string-utf8 100),
  email: (string-utf8 100),
  is-active: bool,
  created-at: uint,
  total-received: uint
})

(define-map merchant-by-owner principal uint)

(define-map payments uint {
  merchant-id: uint,
  amount: uint,
  token: principal,
  description: (string-utf8 256),
  status: (string-ascii 16),
  customer: (optional principal),
  created-at: uint,
  settled-at: (optional uint)
})

(define-map merchant-balances { merchant-id: uint, token: principal } uint)

(define-private (is-gateway)
  (match (var-get gateway-contract) gw (is-eq tx-sender gw) false)
)

(define-private (is-owner)
  (is-eq tx-sender (var-get contract-owner))
)

(define-read-only (get-merchant (merchant-id uint))
  (map-get? merchants merchant-id)
)

(define-read-only (get-merchant-id-by-owner (owner principal))
  (map-get? merchant-by-owner owner)
)

(define-read-only (get-payment (payment-id uint))
  (map-get? payments payment-id)
)

(define-read-only (get-merchant-balance (merchant-id uint) (token principal))
  (default-to u0 (map-get? merchant-balances { merchant-id: merchant-id, token: token }))
)

(define-read-only (get-gateway)
  (var-get gateway-contract)
)

(define-public (register-merchant (owner principal) (business-name (string-utf8 100)) (email (string-utf8 100)))
  (let ((merchant-id (var-get next-merchant-id)))
    (asserts! (not (var-get contract-paused)) ERR-CONTRACT-PAUSED)
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-none (map-get? merchant-by-owner owner)) ERR-MERCHANT-EXISTS)
    (map-set merchants merchant-id { owner: owner, business-name: business-name, email: email, is-active: true, created-at: block-height, total-received: u0 })
    (map-set merchant-by-owner owner merchant-id)
    (var-set next-merchant-id (+ merchant-id u1))
    (ok merchant-id)
  )
)

(define-public (create-payment (merchant-id uint) (amount uint) (token principal) (description (string-utf8 256)))
  (let ((payment-id (var-get next-payment-id)))
    (asserts! (not (var-get contract-paused)) ERR-CONTRACT-PAUSED)
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-some (map-get? merchants merchant-id)) ERR-MERCHANT-NOT-FOUND)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (map-set payments payment-id { merchant-id: merchant-id, amount: amount, token: token, description: description, status: "pending", customer: none, created-at: block-height, settled-at: none })
    (var-set next-payment-id (+ payment-id u1))
    (ok payment-id)
  )
)

(define-public (lock-payment (payment-id uint) (customer principal))
  (let ((payment (unwrap! (map-get? payments payment-id) ERR-PAYMENT-NOT-FOUND)))
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-eq (get status payment) "pending") ERR-PAYMENT-ALREADY-SETTLED)
    (map-set payments payment-id (merge payment { status: "locked", customer: (some customer) }))
    (ok true)
  )
)

(define-public (settle-payment (payment-id uint))
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
    (map-set payments payment-id (merge payment { status: "settled", settled-at: (some block-height) }))
    (map-set merchant-balances { merchant-id: merchant-id, token: token } (+ current-balance amount))
    (map-set merchants merchant-id (merge merchant { total-received: (+ (get total-received merchant) amount) }))
    (ok true)
  )
)

(define-public (dispute-payment (payment-id uint))
  (let ((payment (unwrap! (map-get? payments payment-id) ERR-PAYMENT-NOT-FOUND)))
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-eq (get status payment) "locked") ERR-PAYMENT-ALREADY-SETTLED)
    (map-set payments payment-id (merge payment { status: "disputed" }))
    (ok true)
  )
)

(define-public (deduct-balance (merchant-id uint) (token principal) (amount uint))
  (let ((current (get-merchant-balance merchant-id token)))
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (>= current amount) ERR-INSUFFICIENT-BALANCE)
    (map-set merchant-balances { merchant-id: merchant-id, token: token } (- current amount))
    (ok true)
  )
)

(define-public (set-merchant-active (merchant-id uint) (active bool))
  (let ((merchant (unwrap! (map-get? merchants merchant-id) ERR-MERCHANT-NOT-FOUND)))
    (asserts! (or (is-gateway) (is-eq tx-sender (get owner merchant))) ERR-NOT-AUTHORIZED)
    (map-set merchants merchant-id (merge merchant { is-active: active }))
    (ok true)
  )
)

(define-public (set-gateway (new-gateway principal))
  (begin
    (asserts! (is-owner) ERR-NOT-AUTHORIZED)
    (var-set gateway-contract (some new-gateway))
    (ok true)
  )
)

(define-public (set-contract-paused (paused bool))
  (begin
    (asserts! (is-owner) ERR-NOT-AUTHORIZED)
    (var-set contract-paused paused)
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
`.trim();

// ===== ESCROW =====
const escrow = `
;; StacksBit Escrow Contract
;; Holds funds in escrow, handles multi-token transfers and dispute resolution
;;
;; Author: Terkaa Tarkighir (rogersterkaa@gmail.com)
;; License: MIT

(use-trait sip-010-trait .sip-010-trait.sip-010-trait)

(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-NOT-GATEWAY (err u201))
(define-constant ERR-PAYMENT-NOT-FOUND (err u210))
(define-constant ERR-WRONG-STATUS (err u211))
(define-constant ERR-WRONG-TOKEN (err u212))
(define-constant ERR-CONTRACT-PAUSED (err u230))
(define-constant ERR-INVALID-AMOUNT (err u231))

(define-data-var contract-owner principal tx-sender)
(define-data-var gateway-contract (optional principal) none)
(define-data-var contract-paused bool false)
(define-data-var platform-fee-bps uint u250)
(define-data-var platform-wallet principal tx-sender)

(define-map escrow-records uint {
  token: principal,
  amount: uint,
  merchant: principal,
  customer: principal,
  status: (string-ascii 16),
  ngn-rate: (optional uint)
})

(define-private (is-gateway)
  (match (var-get gateway-contract) gw (is-eq tx-sender gw) false)
)

(define-read-only (get-escrow (payment-id uint))
  (map-get? escrow-records payment-id)
)

(define-read-only (calculate-fee (amount uint))
  (/ (* amount (var-get platform-fee-bps)) u10000)
)

(define-read-only (is-paused)
  (var-get contract-paused)
)

(define-public (lock-funds (payment-id uint) (token <sip-010-trait>) (amount uint) (customer principal) (merchant principal) (ngn-rate (optional uint)))
  (begin
    (asserts! (not (var-get contract-paused)) ERR-CONTRACT-PAUSED)
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (is-none (map-get? escrow-records payment-id)) ERR-WRONG-STATUS)
    (try! (contract-call? token transfer amount customer (as-contract tx-sender) none))
    (map-set escrow-records payment-id { token: (contract-of token), amount: amount, merchant: merchant, customer: customer, status: "locked", ngn-rate: ngn-rate })
    (print { event: "funds-locked", payment-id: payment-id, amount: amount, customer: customer, merchant: merchant })
    (ok true)
  )
)

(define-public (release-funds (payment-id uint) (token <sip-010-trait>))
  (let (
    (escrow (unwrap! (map-get? escrow-records payment-id) ERR-PAYMENT-NOT-FOUND))
    (amount (get amount escrow))
    (merchant (get merchant escrow))
    (fee (calculate-fee amount))
    (payout (- amount fee))
  )
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-eq (get status escrow) "locked") ERR-WRONG-STATUS)
    (asserts! (is-eq (contract-of token) (get token escrow)) ERR-WRONG-TOKEN)
    (try! (as-contract (contract-call? token transfer payout tx-sender merchant none)))
    (try! (as-contract (contract-call? token transfer fee tx-sender (var-get platform-wallet) none)))
    (map-set escrow-records payment-id (merge escrow { status: "released" }))
    (print { event: "funds-released", payment-id: payment-id, merchant: merchant, payout: payout, fee: fee })
    (ok { payout: payout, fee: fee })
  )
)

(define-public (refund-customer (payment-id uint) (token <sip-010-trait>))
  (let (
    (escrow (unwrap! (map-get? escrow-records payment-id) ERR-PAYMENT-NOT-FOUND))
    (amount (get amount escrow))
    (customer (get customer escrow))
  )
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-eq (get status escrow) "disputed") ERR-WRONG-STATUS)
    (asserts! (is-eq (contract-of token) (get token escrow)) ERR-WRONG-TOKEN)
    (try! (as-contract (contract-call? token transfer amount tx-sender customer none)))
    (map-set escrow-records payment-id (merge escrow { status: "refunded" }))
    (print { event: "customer-refunded", payment-id: payment-id, customer: customer, amount: amount })
    (ok true)
  )
)

(define-public (flag-dispute (payment-id uint))
  (let ((escrow (unwrap! (map-get? escrow-records payment-id) ERR-PAYMENT-NOT-FOUND)))
    (asserts! (is-gateway) ERR-NOT-GATEWAY)
    (asserts! (is-eq (get status escrow) "locked") ERR-WRONG-STATUS)
    (map-set escrow-records payment-id (merge escrow { status: "disputed" }))
    (print { event: "dispute-flagged", payment-id: payment-id })
    (ok true)
  )
)

(define-public (set-gateway (new-gateway principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set gateway-contract (some new-gateway))
    (ok true)
  )
)

(define-public (set-platform-fee (new-fee-bps uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-fee-bps u1000) ERR-INVALID-AMOUNT)
    (var-set platform-fee-bps new-fee-bps)
    (ok true)
  )
)

(define-public (set-platform-wallet (new-wallet principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set platform-wallet new-wallet)
    (ok true)
  )
)

(define-public (set-contract-paused (paused bool))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set contract-paused paused)
    (ok true)
  )
)

(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)
`.trim();

// ===== GATEWAY =====
const gateway = `
;; StacksBit Gateway Contract
;; Thin orchestration layer - coordinates merchants + escrow contracts
;;
;; Author: Terkaa Tarkighir (rogersterkaa@gmail.com)
;; License: MIT

(use-trait sip-010-trait .sip-010-trait.sip-010-trait)

(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-NOT-MERCHANT (err u301))
(define-constant ERR-NOT-CUSTOMER (err u302))
(define-constant ERR-INVALID-AMOUNT (err u310))
(define-constant ERR-MERCHANT-NOT-FOUND (err u311))
(define-constant ERR-PAYMENT-NOT-FOUND (err u312))
(define-constant ERR-INVALID-NAME (err u313))
(define-constant ERR-INVALID-EMAIL (err u314))
(define-constant ERR-MERCHANT-INACTIVE (err u315))
(define-constant ERR-WRONG-STATUS (err u316))
(define-constant ERR-CONTRACT-PAUSED (err u330))

(define-data-var contract-owner principal tx-sender)
(define-data-var contract-paused bool false)

(define-read-only (is-paused)
  (var-get contract-paused)
)

(define-public (register-merchant (business-name (string-utf8 100)) (email (string-utf8 100)))
  (let ((caller tx-sender))
    (asserts! (not (var-get contract-paused)) ERR-CONTRACT-PAUSED)
    (asserts! (> (len business-name) u0) ERR-INVALID-NAME)
    (asserts! (> (len email) u0) ERR-INVALID-EMAIL)
    (let ((merchant-id (try! (contract-call? .stacksbit-merchants register-merchant caller business-name email))))
      (print { event: "merchant-registered", merchant-id: merchant-id, owner: caller, business-name: business-name })
      (ok merchant-id)
    )
  )
)

(define-public (create-payment-request (amount uint) (token-contract <sip-010-trait>) (description (string-utf8 256)) (ngn-rate (optional uint)))
  (let (
    (caller tx-sender)
    (merchant-id (unwrap! (contract-call? .stacksbit-merchants get-merchant-id-by-owner caller) ERR-NOT-MERCHANT))
    (merchant (unwrap! (contract-call? .stacksbit-merchants get-merchant merchant-id) ERR-MERCHANT-NOT-FOUND))
  )
    (asserts! (not (var-get contract-paused)) ERR-CONTRACT-PAUSED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (get is-active merchant) ERR-MERCHANT-INACTIVE)
    (let ((payment-id (try! (contract-call? .stacksbit-merchants create-payment merchant-id amount (contract-of token-contract) description))))
      (print { event: "payment-request-created", payment-id: payment-id, merchant-id: merchant-id, amount: amount, description: description, ngn-rate: ngn-rate })
      (ok payment-id)
    )
  )
)

(define-public (pay-invoice (payment-id uint) (token <sip-010-trait>) (ngn-rate (optional uint)))
  (let (
    (caller tx-sender)
    (payment (unwrap! (contract-call? .stacksbit-merchants get-payment payment-id) ERR-PAYMENT-NOT-FOUND))
    (merchant-id (get merchant-id payment))
    (merchant (unwrap! (contract-call? .stacksbit-merchants get-merchant merchant-id) ERR-MERCHANT-NOT-FOUND))
    (amount (get amount payment))
  )
    (asserts! (not (var-get contract-paused)) ERR-CONTRACT-PAUSED)
    (asserts! (is-eq (get status payment) "pending") ERR-WRONG-STATUS)
    (asserts! (get is-active merchant) ERR-MERCHANT-INACTIVE)
    (try! (contract-call? .stacksbit-escrow lock-funds payment-id token amount caller (get owner merchant) ngn-rate))
    (try! (contract-call? .stacksbit-merchants lock-payment payment-id caller))
    (print { event: "invoice-paid", payment-id: payment-id, customer: caller, amount: amount })
    (ok true)
  )
)

(define-public (confirm-delivery (payment-id uint) (token <sip-010-trait>))
  (let (
    (caller tx-sender)
    (payment (unwrap! (contract-call? .stacksbit-merchants get-payment payment-id) ERR-PAYMENT-NOT-FOUND))
  )
    (asserts! (not (var-get contract-paused)) ERR-CONTRACT-PAUSED)
    (asserts! (is-eq (some caller) (get customer payment)) ERR-NOT-CUSTOMER)
    (asserts! (is-eq (get status payment) "locked") ERR-WRONG-STATUS)
    (let ((result (try! (contract-call? .stacksbit-escrow release-funds payment-id token))))
      (try! (contract-call? .stacksbit-merchants settle-payment payment-id))
      (print { event: "delivery-confirmed", payment-id: payment-id, customer: caller, payout: (get payout result), fee: (get fee result) })
      (ok result)
    )
  )
)

(define-public (raise-dispute (payment-id uint))
  (let (
    (caller tx-sender)
    (payment (unwrap! (contract-call? .stacksbit-merchants get-payment payment-id) ERR-PAYMENT-NOT-FOUND))
  )
    (asserts! (not (var-get contract-paused)) ERR-CONTRACT-PAUSED)
    (asserts! (is-eq (some caller) (get customer payment)) ERR-NOT-CUSTOMER)
    (asserts! (is-eq (get status payment) "locked") ERR-WRONG-STATUS)
    (try! (contract-call? .stacksbit-escrow flag-dispute payment-id))
    (try! (contract-call? .stacksbit-merchants dispute-payment payment-id))
    (print { event: "dispute-raised", payment-id: payment-id, customer: caller })
    (ok true)
  )
)

(define-public (resolve-dispute-refund (payment-id uint) (token <sip-010-trait>))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (try! (contract-call? .stacksbit-escrow refund-customer payment-id token))
    (print { event: "dispute-resolved-refund", payment-id: payment-id })
    (ok true)
  )
)

(define-public (resolve-dispute-release (payment-id uint) (token <sip-010-trait>))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (let ((result (try! (contract-call? .stacksbit-escrow release-funds payment-id token))))
      (try! (contract-call? .stacksbit-merchants settle-payment payment-id))
      (print { event: "dispute-resolved-release", payment-id: payment-id })
      (ok result)
    )
  )
)

(define-public (withdraw (amount uint) (token <sip-010-trait>))
  (let (
    (caller tx-sender)
    (merchant-id (unwrap! (contract-call? .stacksbit-merchants get-merchant-id-by-owner caller) ERR-NOT-MERCHANT))
  )
    (asserts! (not (var-get contract-paused)) ERR-CONTRACT-PAUSED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (try! (contract-call? .stacksbit-merchants deduct-balance merchant-id (contract-of token) amount))
    (try! (as-contract (contract-call? token transfer amount tx-sender caller none)))
    (print { event: "merchant-withdrawal", merchant-id: merchant-id, merchant: caller, amount: amount, token: (contract-of token) })
    (ok true)
  )
)

(define-read-only (get-payment-info (payment-id uint))
  (contract-call? .stacksbit-merchants get-payment payment-id)
)

(define-read-only (get-merchant-info (merchant-id uint))
  (contract-call? .stacksbit-merchants get-merchant merchant-id)
)

(define-read-only (get-escrow-info (payment-id uint))
  (contract-call? .stacksbit-escrow get-escrow payment-id)
)

(define-read-only (get-merchant-balance (merchant-id uint) (token principal))
  (contract-call? .stacksbit-merchants get-merchant-balance merchant-id token)
)

(define-public (set-contract-paused (paused bool))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set contract-paused paused)
    (ok true)
  )
)

(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)
`.trim();

// Write all three files
fs.writeFileSync('contracts/stacksbit-merchants.clar', merchants, {encoding: 'utf8'});
fs.writeFileSync('contracts/stacksbit-escrow.clar', escrow, {encoding: 'utf8'});
fs.writeFileSync('contracts/stacksbit-gateway.clar', gateway, {encoding: 'utf8'});

console.log('merchants:', fs.statSync('contracts/stacksbit-merchants.clar').size, 'bytes');
console.log('escrow:', fs.statSync('contracts/stacksbit-escrow.clar').size, 'bytes');
console.log('gateway:', fs.statSync('contracts/stacksbit-gateway.clar').size, 'bytes');
console.log('All contracts written successfully!');