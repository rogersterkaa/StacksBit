// settlement.ts — Core settlement logic
// Bridges on-chain payment release to off-chain NGN payout.
// Called when delivery-confirmed event is detected on Stacks.

import { getBtcToNgnRate, satoshiToNgn } from "./fx";
import { sendTransfer } from "./paystack";

export interface SettlementPayload {
  paymentId: string;
  merchant: string;         // Stacks address
  amountSatoshis: number;   // sBTC amount in satoshis
  recipientCode: string;    // Paystack recipient code
  ngnRate?: number;         // Optional locked rate from contract
}

export interface SettlementResult {
  status: "success" | "failed";
  paymentId: string;
  ngnAmount?: number;
  paystackReference?: string;
  error?: string;
}

export async function settlePayment(
  payload: SettlementPayload
): Promise<SettlementResult> {
  const { paymentId, merchant, amountSatoshis, recipientCode, ngnRate } = payload;

  console.log(`[Settlement] Starting settlement for payment #${paymentId}`);
  console.log(`[Settlement] Merchant: ${merchant}`);
  console.log(`[Settlement] Amount: ${amountSatoshis} satoshis`);

  try {
    // Step 1: Get FX rate
    // Use locked rate from contract if available (protects merchant from slippage)
    // Otherwise fetch live rate
    let rate: number;
    if (ngnRate && ngnRate > 0) {
      rate = ngnRate;
      console.log(`[Settlement] Using locked rate from contract: ₦${rate}`);
    } else {
      rate = await getBtcToNgnRate();
    }

    // Step 2: Calculate NGN amount
    // Deduct 2.5% platform fee (already deducted on-chain, but we record it)
    const grossNgn = satoshiToNgn(amountSatoshis, rate);

    // Step 3: Add settlement delay buffer (5 minutes)
    // Protects against edge cases and reorgs
    await new Promise(resolve => setTimeout(resolve, 5 * 60 * 1000));
    console.log(`[Settlement] Delay complete. Sending ₦${grossNgn.toFixed(2)} to ${recipientCode}`);

    // Step 4: Send via Paystack
    const result = await sendTransfer(grossNgn, recipientCode, paymentId);

    console.log(`[Settlement] ✅ Success for payment #${paymentId}`);
    return {
      status: "success",
      paymentId,
      ngnAmount: grossNgn,
      paystackReference: result.data?.transfer_code,
    };

  } catch (err: any) {
    console.error(`[Settlement] ❌ Failed for payment #${paymentId}:`, err.message);
    return {
      status: "failed",
      paymentId,
      error: err.message,
    };
  }
}