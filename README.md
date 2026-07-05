# StacksBit — React Frontend

**Fraud-protection escrow for African commerce — mobile-ready, role-based, built on Stacks (Bitcoin L2)**

🔗 **Live app:** https://stacksbit-react.vercel.app  
🐙 **Smart contracts:** https://github.com/rogersterkaa/StacksBit  
📱 **Mobile:** Open inside Leather wallet's dapp browser

---

## What This Is

This is the React + TypeScript frontend for StacksBit — a bilateral fraud-protection platform for Nigerian merchants and buyers. It replaces the original vanilla JavaScript frontend with a properly structured, mobile-functional, role-based application.

> "Send money first and pray" is how most online commerce works in Nigeria.  
> StacksBit fixes this — payment locks in escrow until delivery is confirmed.  
> Nobody loses. Both sides protected.

---

## Key Features

- **Role-based entry point** — merchants and buyers see different navigation from the start
- **Independent wallet slots** — merchant and buyer can each connect their own separate wallet in the same session (fixes the Week 4 pilot blocker)
- **Real Payment ID display** — polls on-chain after creation so merchants don't need a block explorer
- **Mobile-functional** — works on phone via Leather wallet's built-in dapp browser
- **Full escrow flow** — register → create invoice → pay → confirm delivery → dispute
- **Real-time transaction history** — pulls directly from Hiro API
- **Fraud detection display** — risk gauge, fraud signals, USSD Phase 2 notice

---

## Pages

| Page | Role | Description |
|------|------|-------------|
| Landing Screen | Both | Merchant/buyer role selection on first load |
| Dashboard | Merchant | Quick actions, wallet status, escrow notice |
| Register Merchant | Merchant | On-chain business registration |
| Create Payment | Merchant | Invoice creation with real Payment ID |
| Pay Invoice | Buyer | Escrow payment + confirm delivery / dispute |
| Transactions | Both | Real on-chain history from Hiro API |
| Risk Panel | Merchant | Fraud score gauge, signal monitoring, USSD Phase 2 |

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Framework | React 19 + TypeScript |
| Build tool | Vite |
| Wallet | Leather (via @stacks/connect) |
| Contracts | @stacks/transactions |
| Styling | CSS custom properties (no UI library) |
| Deployment | Vercel |
| Network | Stacks Testnet |

---

## Getting Started

```bash
# Clone the repo
git clone https://github.com/rogersterkaa/stacksbit-react.git
cd stacksbit-react

# Install dependencies
npm install

# Start dev server
npm run dev
```

Open `http://localhost:5173` in your browser.

**To connect on mobile:** open the URL inside Leather wallet's built-in dapp browser — the wallet extension cannot inject into standard mobile browsers.

---

## Contract Configuration

The app connects to these deployed contracts on Stacks Testnet:

```
Deployer: ST3GTDAAVRPKHCC45FFW0540MPTDHGWWRMB5DS4Q0
Gateway:  stacksbit-gateway
Token:    sbtc
```

To switch networks or contracts, update the constants at the top of each page component.

---

## Architecture

```
src/
  components/
    LandingScreen.tsx   — merchant/buyer role split entry point
    Sidebar.tsx         — role-aware navigation
    Topbar.tsx          — mobile menu + context-aware wallet display
  context/
    WalletContext.tsx   — independent merchant + buyer wallet slots
  pages/
    Dashboard.tsx
    RegisterMerchant.tsx
    CreatePayment.tsx
    PayInvoice.tsx
    Transactions.tsx
    RiskPanel.tsx
  index.css             — design tokens + component styles
  App.tsx               — routing + role state
  main.tsx
```

---

## Validation Background

This frontend was rebuilt as part of the **Stacks Foundry Validate** program (Q2 2026) after pilot testing with real merchants in Jos, Nigeria revealed two adoption blockers:

1. **Mobile UI** — the original frontend didn't work on phones; merchants run their businesses from phones, not computers
2. **Single-wallet sessions** — the original app auto-registered one wallet to both merchant and buyer roles, making live two-sided transactions impossible

Both blockers are resolved in this rebuild.

---

## What's Next

- [ ] USSD offline confirmation (Africa's Talking API — Phase 2)
- [ ] NGN settlement via Paystack
- [ ] Mainnet deployment
- [ ] Dispute resolution UI
- [ ] Merchant reputation scoring dashboard

---

## Related Repos

- **Smart contracts:** https://github.com/rogersterkaa/StacksBit
- **Stacks MCP Server:** https://github.com/rogersterkaa/stacks-mcp-server
- **Original JS frontend (deprecated):** https://github.com/rogersterkaa/StacksBit-Frontend

---

## Builder

**Terkaa Tarkighir (Rogers)**  
Blockchain developer — Jos, Plateau State, Nigeria  
📧 rogersterkaa@gmail.com  
🐙 github.com/rogersterkaa

---

## Hire Me

Need a custom MCP server, Stacks integration, or React + TypeScript blockchain frontend?

📧 rogersterkaa@gmail.com