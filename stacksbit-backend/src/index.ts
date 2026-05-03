// index.ts — StacksBit Settlement Backend
// Entry point. Starts Express server and blockchain listener.
//
// Architecture: Option B (Payout Trigger Model)
// We never hold funds. We only read on-chain events and trigger Paystack payouts.

import express from "express";
import bodyParser from "body-parser";
import dotenv from "dotenv";
import { pollEvents } from "./listener";
import { handlePaystackWebhook } from "./webhook";

// Load environment variables
dotenv.config();

const app = express();
const PORT = process.env.PORT || 4000;

// Middleware
app.use(bodyParser.json());

// Health check — confirms server is running
app.get("/health", (req, res) => {
  res.json({
    status: "ok",
    service: "StacksBit Settlement Backend",
    network: "Stacks Testnet",
    timestamp: new Date().toISOString(),
  });
});

// Paystack webhook endpoint
// Paystack calls this URL when transfer succeeds or fails
app.post("/webhook/paystack", handlePaystackWebhook);

// Manual settlement trigger — useful for testing and demos
// POST /settle with { paymentId, merchant, amountSatoshis, recipientCode }
app.post("/settle", async (req, res) => {
  const { paymentId, merchant, amountSatoshis, recipientCode } = req.body;

  if (!paymentId || !merchant || !amountSatoshis || !recipientCode) {
    res.status(400).json({ error: "Missing required fields" });
    return;
  }

  const { settlePayment } = await import("./settlement");
  const result = await settlePayment({
    paymentId,
    merchant,
    amountSatoshis,
    recipientCode,
  });

  res.json(result);
});

// Start blockchain event listener
// Polls Stacks API every 10 seconds for new delivery-confirmed events
const POLL_INTERVAL = 10_000;
console.log(`[Listener] Starting — polling every ${POLL_INTERVAL / 1000}s`);
setInterval(pollEvents, POLL_INTERVAL);

// Run once immediately on startup
pollEvents();

// Start server
app.listen(PORT, () => {
  console.log(`[Server] StacksBit Settlement Backend running on port ${PORT}`);
  console.log(`[Server] Health check: http://localhost:${PORT}/health`);
  console.log(`[Server] Webhook endpoint: http://localhost:${PORT}/webhook/paystack`);
  console.log(`[Server] Manual settle: POST http://localhost:${PORT}/settle`);
});