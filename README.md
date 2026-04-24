# StacksBit
**Bitcoin payments for African merchants. Simple. Safe. Non-custodial.**
> Non-custodial Bitcoin payment gateway for African merchants, built on Stacks blockchain.

![Tests](https://img.shields.io/badge/tests-31%2F31%20passing-brightgreen)
![License](https://img.shields.io/badge/license-MIT-blue)
![Network](https://img.shields.io/badge/network-Stacks%20Testnet-orange)
![Status](https://img.shields.io/badge/status-live%20on%20testnet-brightgreen)

## Live Deployment (Testnet)

StacksBit is live on Stacks testnet. All contracts are deployed and verified.

### Deployed Contract Addresses

| Contract | Address |
|----------|---------|
| stacksbit-gateway | `ST3GTDAAVRPKHCC45FFW0540MPTDHGWWRMB5DS4Q0.stacksbit-gateway` |
| stacksbit-merchants | `ST3GTDAAVRPKHCC45FFW0540MPTDHGWWRMB5DS4Q0.stacksbit-merchants` |
| stacksbit-escrow | `ST3GTDAAVRPKHCC45FFW0540MPTDHGWWRMB5DS4Q0.stacksbit-escrow` |
| sbtc | `ST3GTDAAVRPKHCC45FFW0540MPTDHGWWRMB5DS4Q0.sbtc` |
| sip-010-trait | `ST3GTDAAVRPKHCC45FFW0540MPTDHGWWRMB5DS4Q0.sip-010-trait` |
| stacksbit-fraud | `ST3GTDAAVRPKHCC45FFW0540MPTDHGWWRMB5DS4Q0.stacksbit-fraud` |
| stacksbit-fraud-v2 | `ST3GTDAAVRPKHCC45FFW0540MPTDHGWWRMB5DS4Q0.stacksbit-fraud-v2` |
| stacksbit-escrow-v2 | `ST3GTDAAVRPKHCC45FFW0540MPTDHGWWRMB5DS4Q0.stacksbit-escrow-v2` |

### Verified Transactions

Full payment flow tested end-to-end on Stacks testnet:

- register-merchant — confirmed
- create-payment-request — confirmed
- pay-invoice (funds locked in escrow) — confirmed
- confirm-delivery (funds released to merchant) — confirmed

Explorer: https://explorer.hiro.so/address/ST3GTDAAVRPKHCC45FFW0540MPTDHGWWRMB5DS4Q0?chain=testnet

### Interact with Live Contracts

Test the contracts directly on Stacks Explorer sandbox:
https://explorer.hiro.so/sandbox/contract-call?chain=testnet

Enter contract address: `ST3GTDAAVRPKHCC45FFW0540MPTDHGWWRMB5DS4Q0`

## Problem

Small businesses in Nigeria and across Africa cannot easily accept Bitcoin:

- Existing tools like BTCPay are too complex for non-technical merchants
- Custodial solutions require trusting a third party with funds
- No built-in dispute protection means fraud risk
- Volatility discourages adoption without local currency settlement
- No integration with local payment systems like Naira

## Solution

StacksBit is a trustless Bitcoin payment gateway that makes accepting Bitcoin as simple as using Paystack:

1. Merchant creates a payment link
2. Customer pays in Bitcoin (sBTC)
3. Funds locked in Clarity smart contract escrow
4. Merchant delivers goods or service
5. Customer confirms, funds released automatically
6. Optional Naira settlement via Paystack/Flutterwave

## Architecture

```
Frontend (Web/Mobile)
        |
Gateway Contract (stacksbit-gateway.clar)
        |
   +----+----+
   |         |
Merchants  Escrow
Contract   Contract
(storage)  (funds)
```

### Contracts

| Contract | Purpose |
|----------|---------|
| stacksbit-gateway.clar | Orchestrates payment flow |
| stacksbit-merchants.clar | Stores merchant profiles and payment records |
| stacksbit-escrow.clar | Holds funds and handles disputes |
| sip-010-trait.clar | Standard token interface |

## Features

- Non-Custodial Escrow: Funds held in smart contracts, never in company wallets
- Built-In Dispute Resolution: Customer or merchant can dispute; admin arbitrates
- Multi-Token Support: Works with sBTC, USDC, or any SIP-010 token
- Naira Settlement Ready: Optional NGN payout via Paystack/Flutterwave
- Simple Onboarding: Merchants register in seconds
- Transparent Fees: 2.5% platform fee, capped at 10%
- AI Fraud Detection: On-chain merchant reputation tracking with risk scoring API (green/yellow/red)
- Merchant Reputation System: On-chain trust scores (0-100) with badges (New, Rising, Trusted, Elite) that build automatically with every successful payment
- Escrow Time Lock: Funds auto-refund to customer after 144 blocks (~24 hours) if merchant never delivers -- no admin needed, fully trustless
- Offline Confirmation: Merchants confirm delivery via SMS or USSD (*384#) with zero internet needed. Works on any basic phone in Nigeria.

## 🌍 Real-World Readiness

StacksBit is not a theory. It is built specifically 
for how commerce actually works in emerging markets.

### Built for Low-Connectivity Markets
- **USSD confirmation** — merchants dial `*384*paymentID#` 
  from any basic phone, zero internet required
- **SMS confirmation** — merchant replies to SMS to 
  release funds, works on the cheapest devices
- **Agent-based confirmation** — trusted local agents 
  can confirm on behalf of merchants in rural areas
- No smartphone required to receive Bitcoin payments

### Built for African Merchants
- **Naira settlement ready** — merchants can opt to 
  receive NGN via Paystack/Flutterwave instead of sBTC
- **NGN rate stored on-chain** — every payment records 
  the exchange rate at time of transaction
- **Simple onboarding** — merchants register in seconds 
  with just a business name and email
- Designed for the 39 million Nigerian SMEs who are 
  underserved by existing payment infrastructure

### Trust Without Custody
- Funds held in auditable Clarity smart contracts
- No company wallet ever touches merchant funds
- Automatic refund after 144 blocks (~24 hours) 
  if merchant never delivers — fully trustless
- Dispute resolution built into the protocol

### Fraud Protection Built In
- Every merchant has an on-chain reputation score
- Dispute rate tracked automatically
- Suspicious merchants flagged before payment
- Blacklist system for known bad actors
- Risk scores: 0 (safe) to 100 (blocked)

### Proven on Stacks Testnet
- All 8 contracts deployed and verified on-chain
- Full payment flow tested end-to-end
- 31 passing unit tests proving real money flows
- Explorer: https://explorer.hiro.so/address/ST3GTDAAVRPKHCC45FFW0540MPTDHGWWRMB5DS4Q0?chain=testnet

> "This is how a merchant in Nigeria accepts Bitcoin 
> without trusting anyone."

## Getting Started

```bash
git clone https://github.com/rogersterkaa/StacksBit.git
cd StacksBit
npm install
clarinet check
npm test
```

## Test Results

```
Test Files  1 passed (1)
     Tests  31 passed (31)
```

## Usage

### Register as a Merchant

```clarity
(contract-call? .stacksbit-gateway register-merchant
  u"Lagos Coffee Shop"
  u"shop@lagoscoffee.com"
)
;; Returns: (ok u1)
```

### Create a Payment Request

```clarity
(contract-call? .stacksbit-gateway create-payment-request
  u50000000
  .sbtc
  u"Coffee x2"
  none
)
;; Returns: (ok u1) -- share this payment-id with customer
```

### Customer Pays Invoice

```clarity
(contract-call? .stacksbit-gateway pay-invoice
  u1
  .sbtc
  none
)
;; Funds locked in escrow
```

### Confirm Delivery

```clarity
(contract-call? .stacksbit-gateway confirm-delivery
  u1
  .sbtc
)
;; Merchant receives 97.5%, platform receives 2.5%
```

### Withdraw Funds

```clarity
(contract-call? .stacksbit-gateway withdraw
  u50000000
  .sbtc
)
```

## Security

- Non-Custodial: Funds in auditable smart contracts
- Access Control: All write functions gated by authorization
- Atomic Transfers: Fee and payout happen together or not at all
- Status Protection: Payment status tracked (pending, locked, settled, disputed)
- Emergency Pause: Owner can pause all operations

## Test Coverage

| Category | Tests |
|----------|-------|
| Merchant Registration | 6 |
| Payment Requests | 4 |
| Escrow and Fund Locking | 2 |
| Dispute Resolution | 2 |
| Merchant Storage | 4 |
| Access Control | 6 |
| Fee Calculations | 2 |
| **Total** | **31** |

## Project Stats

| Metric | Value |
|--------|-------|
| Clarity contracts | 8 |
| Public functions | 24 |
| Unit tests | 31 |
| Test coverage | 100% |

## Roadmap

### Phase 1 - MVP (Complete)
- 8 production-ready contracts
- 31 passing unit tests
- Deployed and verified on Stacks testnet
- Full payment flow tested on-chain

### Phase 2 - Naira Settlement (Q2/Q3 2026)
- Paystack/Flutterwave integration
- NGN/BTC exchange rate oracle
- Nigeria merchant pilot

### Phase 3 - Multi-Token (Q4 2026)
- USDC support
- Additional SIP-010 tokens

### Phase 4 - DAO Governance (2027)
- Community-driven dispute resolution
- Decentralized fee management

## FAQ

**Is StacksBit custodial?**
No. Funds are held in Clarity smart contracts, never in company wallets.

**What tokens are supported?**
sBTC currently. Any SIP-010 compatible token can be added.

**What is the platform fee?**
2.5% on successful transactions, capped at 10%.

**When is mainnet?**
Contracts are live on Stacks testnet. Mainnet deployment targeted for Q3 2026 after security audit.

**What is Naira settlement?**
Merchants can opt to receive NGN. The contract records the obligation on-chain and a backend triggers Paystack/Flutterwave payout.

## License

MIT License

## Contact

- GitHub: https://github.com/rogersterkaa/StacksBit
- Email: rogersterkaa@gmail.com

## Contributing
Pull requests are welcome. For major changes, please open an issue first.
---

Built for African merchants. Powered by Bitcoin.
