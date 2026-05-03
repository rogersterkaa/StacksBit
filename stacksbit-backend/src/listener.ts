// listener.ts — Stacks blockchain event listener
// Polls Hiro API every 10 seconds for new confirmed transactions.
// Filters for delivery-confirmed events from our gateway contract.
// Production upgrade: replace polling with Stacks event indexer subscription.

import axios from "axios";
import { settlePayment } from "./settlement";

// Track processed transactions to avoid double-settlement
const processedTxs = new Set<string>();

interface StacksEvent {
  contract_log?: {
    contract_id: string;
    topic: string;
    value: {
      repr: string;
    };
  };
}

interface StacksTx {
  tx_id: string;
  tx_status: string;
  tx_type: string;
  events: StacksEvent[];
}

// Parse the Clarity print event from contract log
// Event format: { event: "delivery-confirmed", payment-id: u1, merchant: ..., amount: u10000000, ngn-rate: none }
function parseDeliveryEvent(repr: string): {
  paymentId: string;
  merchant: string;
  amount: number;
  ngnRate: number | null;
} | null {
  try {
    // Extract payment-id
    const paymentIdMatch = repr.match(/payment-id:\s*u(\d+)/);
    const merchantMatch = repr.match(/merchant:\s*'([A-Z0-9]+)/);
    const amountMatch = repr.match(/amount:\s*u(\d+)/);
    const ngnRateMatch = repr.match(/ngn-rate:\s*\(some u(\d+)\)/);

    if (!paymentIdMatch || !merchantMatch || !amountMatch) return null;

    return {
      paymentId: paymentIdMatch[1],
      merchant: merchantMatch[1],
      amount: parseInt(amountMatch[1]),
      ngnRate: ngnRateMatch ? parseInt(ngnRateMatch[1]) : null,
    };
  } catch {
    return null;
  }
}

// Poll Stacks API for new transactions on our gateway contract
export async function pollEvents(): Promise<void> {
  const STACKS_API = process.env.STACKS_API;
  const CONTRACT = process.env.STACKSBIT_CONTRACT;
  const contractAddress = CONTRACT?.split('.')[0];
  
  try {
    console.log(`[Listener] Polling: ${STACKS_API}/extended/v1/address/${contractAddress}/transactions`);
    const res = await axios.get(
      `${STACKS_API}/extended/v1/address/${contractAddress}/transactions`,
      {
        params: { limit: 20 },
        timeout: 8000,
      }
    );

    const txs: StacksTx[] = res.data.results || [];

    for (const tx of txs) {
      // Skip already processed or failed transactions
      if (processedTxs.has(tx.tx_id)) continue;
      if (tx.tx_status !== "success") continue;

      // Look for delivery-confirmed event in contract logs
      for (const event of tx.events || []) {
        if (!event.contract_log) continue;
        if (!event.contract_log.contract_id.includes("stacksbit-gateway")) continue;

        const repr = event.contract_log.value.repr;
        if (!repr.includes("delivery-confirmed")) continue;

        console.log(`[Listener] Found delivery-confirmed in tx: ${tx.tx_id}`);

        const parsed = parseDeliveryEvent(repr);
        if (!parsed) {
          console.warn("[Listener] Could not parse event:", repr);
          continue;
        }

        // Mark as processed immediately to prevent double-settlement
        processedTxs.add(tx.tx_id);

        console.log(`[Listener] Payment #${parsed.paymentId} confirmed`);
        console.log(`[Listener] Merchant: ${parsed.merchant}`);
        console.log(`[Listener] Amount: ${parsed.amount} satoshis`);

        // TODO: Look up merchant's Paystack recipient code from DB
        // For MVP: hardcoded test recipient
        const recipientCode = process.env.TEST_RECIPIENT_CODE || "RCP_test";

        // Trigger settlement (non-blocking)
        settlePayment({
          paymentId: parsed.paymentId,
          merchant: parsed.merchant,
          amountSatoshis: parsed.amount,
          recipientCode,
          ngnRate: parsed.ngnRate || undefined,
        }).then(result => {
          console.log(`[Listener] Settlement result:`, result);
        });
      }
    }
  } catch (err: any) {
    console.error("[Listener] Poll error:", err.message);
  }
}
