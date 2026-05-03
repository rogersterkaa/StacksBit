// webhook.ts — Paystack webhook handler
// Receives transfer status updates from Paystack.
// Verify signature before processing — critical for security.

import { Request, Response } from "express";
import { verifyWebhookSignature } from "./paystack";

export function handlePaystackWebhook(req: Request, res: Response): void {
  // Step 1: Verify webhook signature
  // Paystack sends X-Paystack-Signature header with every request
  const signature = req.headers["x-paystack-signature"] as string;
  const rawBody = JSON.stringify(req.body);

  if (!verifyWebhookSignature(rawBody, signature)) {
    console.warn("[Webhook] Invalid signature — rejected");
    res.status(401).json({ error: "Invalid signature" });
    return;
  }

  const event = req.body;
  console.log(`[Webhook] Event received: ${event.event}`);

  switch (event.event) {
    case "transfer.success":
      // Transfer completed — update DB status to "settled"
      console.log(`[Webhook] ✅ Transfer successful`);
      console.log(`[Webhook] Reference: ${event.data.transfer_code}`);
      console.log(`[Webhook] Amount: ₦${event.data.amount / 100}`);
      console.log(`[Webhook] Recipient: ${event.data.recipient.name}`);
      // TODO: Update payment status in DB to "settled"
      break;

    case "transfer.failed":
      // Transfer failed — log for retry queue
      console.error(`[Webhook] ❌ Transfer failed`);
      console.error(`[Webhook] Reason: ${event.data.reason}`);
      // TODO: Add to retry queue
      break;

    case "transfer.reversed":
      // Transfer reversed — flag for manual review
      console.warn(`[Webhook] ⚠️ Transfer reversed`);
      // TODO: Alert admin and freeze merchant account
      break;

    default:
      console.log(`[Webhook] Unhandled event: ${event.event}`);
  }

  // Always respond 200 — Paystack will retry if it doesn't get 200
  res.sendStatus(200);
}