// paystack.ts — Paystack Transfer API integration
// Handles recipient creation and NGN transfers to merchant bank accounts.
// All amounts in KOBO (1 NGN = 100 kobo).

import axios from "axios";

const client = axios.create({
  baseURL: "https://api.paystack.co",
  headers: {
    Authorization: `Bearer ${process.env.PAYSTACK_SECRET}`,
    "Content-Type": "application/json",
  },
  timeout: 10000,
});

// Create a transfer recipient (merchant's bank account)
// Must be done once per merchant before sending money
export async function createRecipient(
  name: string,
  accountNumber: string,
  bankCode: string
): Promise<string> {
  try {
    const res = await client.post("/transferrecipient", {
      type: "nuban",
      name,
      account_number: accountNumber,
      bank_code: bankCode,
      currency: "NGN",
    });
    const recipientCode = res.data.data.recipient_code;
    console.log(`[Paystack] Recipient created: ${recipientCode}`);
    return recipientCode;
  } catch (err: any) {
    console.error("[Paystack] Failed to create recipient:", err.response?.data);
    throw new Error("Failed to create Paystack recipient");
  }
}

// Send NGN to merchant bank account
// amount is in NGN (we convert to kobo internally)
export async function sendTransfer(
  amountNgn: number,
  recipientCode: string,
  paymentId: string
): Promise<any> {
  try {
    const amountKobo = Math.floor(amountNgn * 100);
    const res = await client.post("/transfer", {
      source: "balance",
      amount: amountKobo,
      recipient: recipientCode,
      reason: `StacksBit settlement — Payment #${paymentId}`,
    });
    console.log(`[Paystack] Transfer initiated: ₦${amountNgn} → ${recipientCode}`);
    return res.data;
  } catch (err: any) {
    console.error("[Paystack] Transfer failed:", err.response?.data);
    throw new Error("Paystack transfer failed");
  }
}

// Verify Paystack webhook signature
// Critical for production — prevents fake webhook calls
import crypto from "crypto";

export function verifyWebhookSignature(
  payload: string,
  signature: string
): boolean {
  const hash = crypto
    .createHmac("sha512", process.env.PAYSTACK_SECRET || "")
    .update(payload)
    .digest("hex");
  return hash === signature;
}