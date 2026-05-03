// fx.ts — BTC to NGN conversion
// Uses CoinGecko free API. No key required for MVP.
// Production: add margin (1-2%) to protect against slippage.

import axios from "axios";

export async function getBtcToNgnRate(): Promise<number> {
  try {
    const res = await axios.get(
      "https://api.coingecko.com/api/v3/simple/price",
      {
        params: {
          ids: "bitcoin",
          vs_currencies: "ngn",
        },
        timeout: 5000,
      }
    );
    const rate = res.data.bitcoin.ngn;
    console.log(`[FX] BTC/NGN rate: ₦${rate.toLocaleString()}`);
    return rate;
  } catch (err) {
    console.error("[FX] Failed to fetch rate:", err);
    throw new Error("FX rate unavailable");
  }
}

// Convert sBTC (in microunits) to NGN
// sBTC uses 8 decimal places like Bitcoin
export function satoshiToNgn(satoshis: number, rate: number): number {
  const btc = satoshis / 100_000_000;
  const ngn = btc * rate;
  console.log(`[FX] ${satoshis} satoshis = ${btc} BTC = ₦${ngn.toFixed(2)}`);
  return ngn;
}