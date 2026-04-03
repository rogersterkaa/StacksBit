# StacksBit

> Non-custodial Bitcoin payment gateway for African merchants, built on Stacks blockchain.

![Tests](https://img.shields.io/badge/tests-28%2F28%20passing-brightgreen)
![License](https://img.shields.io/badge/license-MIT-blue)

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
     Tests  28 passed (28)
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
| **Total** | **28** |

## Project Stats

| Metric | Value |
|--------|-------|
| Clarity contracts | 3 |
| Public functions | 24 |
| Unit tests | 28 |
| Test coverage | 100% |

## Roadmap

### Phase 1 - MVP (Complete)
- 3 production-ready contracts
- 28 passing unit tests
- Testnet deployment ready

### Phase 2 - Naira Settlement (Q3 2026)
- Paystack/Flutterwave integration
- NGN/BTC exchange rate oracle
- Nigeria merchant pilot

### Phase 3 - Multi-Token (Q4 2026)
- USDC support
- Additional SIP-010 tokens

### Phase 4 - DAO Governance (2027)
- Community-driven dispute resolution
- Decentralized fee management

## Grant Applications

### Stacks Grants ($15K - $30K)
- Focus: Bitcoin payment infrastructure
- Apply: https://grants.stacks.org

### Superteam Microgrant ($5K - $10K)
- Focus: African Bitcoin adoption
- Apply: https://superteam.fun

## FAQ

**Is StacksBit custodial?**
No. Funds are held in Clarity smart contracts, never in company wallets.

**What tokens are supported?**
sBTC currently. Any SIP-010 compatible token can be added.

**What is the platform fee?**
2.5% on successful transactions, capped at 10%.

**When is mainnet?**
After security audit. Targeted for Q2/Q3 2026.

**What is Naira settlement?**
Merchants can opt to receive NGN. The contract records the obligation on-chain and a backend triggers Paystack/Flutterwave payout.

## License

MIT License

## Contact

- GitHub: https://github.com/rogersterkaa/StacksBit
- Email: rogersterkaa@gmail.com

---

Built for African merchants. Powered by Bitcoin.
