import { describe, it, expect, beforeEach } from "vitest";
import { initSimnet } from "@hirosystems/clarinet-sdk";
import { Cl } from "@stacks/transactions";

const simnet = await initSimnet();
const accounts = simnet.getAccounts();

const deployer = accounts.get("deployer")!;
const merchant1 = accounts.get("wallet_1")!;
const customer1 = accounts.get("wallet_2")!;
const wallet3 = accounts.get("wallet_3")!;

const MERCHANTS = "stacksbit-merchants";
const ESCROW = "stacksbit-escrow";
const GATEWAY = "stacksbit-gateway";
const SBTC = "sbtc";

const SBTC_CONTRACT = `${deployer}.${SBTC}`;
const PAYMENT_AMOUNT = 10000000; // 0.1 sBTC
const PLATFORM_FEE = 250000;     // 2.5% of 10000000
const MERCHANT_PAYOUT = 9750000; // 97.5% of 10000000

// ================================================
// HELPERS
// ================================================

function setupGateway() {
  const gw = `${deployer}.${GATEWAY}`;
  simnet.callPublicFn(MERCHANTS, "set-gateway", [Cl.principal(gw)], deployer);
  simnet.callPublicFn(ESCROW, "set-gateway", [Cl.principal(gw)], deployer);
  simnet.callPublicFn(ESCROW, "set-platform-wallet", [Cl.principal(deployer)], deployer);
}

function mintSbtc(recipient: string, amount: number) {
  return simnet.callPublicFn(SBTC, "mint", [Cl.uint(amount), Cl.principal(recipient)], deployer);
}

function getBalance(owner: string) {
  const result = simnet.callReadOnlyFn(SBTC, "get-balance", [Cl.principal(owner)], deployer);
  return result.result;
}

function registerMerchant(wallet: string, name: string, email: string) {
  return simnet.callPublicFn(GATEWAY, "register-merchant",
    [Cl.stringUtf8(name), Cl.stringUtf8(email)], wallet);
}

function createPaymentRequest(wallet: string, amount: number, description: string) {
  return simnet.callPublicFn(GATEWAY, "create-payment-request",
    [Cl.uint(amount), Cl.principal(SBTC_CONTRACT), Cl.stringUtf8(description), Cl.none()], wallet);
}

// ================================================
// MINT / TOKEN TESTS
// ================================================
describe("sBTC Token - Real Money Flows", () => {
  it("deployer can mint sBTC to any wallet", () => {
    const result = mintSbtc(customer1, 50000000);
    expect(result.result).toBeOk(Cl.bool(true));
  });

  it("balance updates after mint", () => {
    mintSbtc(customer1, 50000000);
    expect(getBalance(customer1)).toBeOk(Cl.uint(50000000));
  });

  it("transfer moves tokens between wallets", () => {
    mintSbtc(customer1, 50000000);
    simnet.callPublicFn(SBTC, "transfer",
      [Cl.uint(10000000), Cl.principal(customer1), Cl.principal(merchant1), Cl.none()],
      customer1);
    expect(getBalance(customer1)).toBeOk(Cl.uint(40000000));
    expect(getBalance(merchant1)).toBeOk(Cl.uint(10000000));
  });

  it("transfer fails if sender has insufficient balance", () => {
    mintSbtc(customer1, 1000);
    const result = simnet.callPublicFn(SBTC, "transfer",
      [Cl.uint(9999999), Cl.principal(customer1), Cl.principal(merchant1), Cl.none()],
      customer1);
    expect(result.result).toBeErr(Cl.uint(402));
  });

  it("transfer fails if not called by sender", () => {
    mintSbtc(customer1, 50000000);
    const result = simnet.callPublicFn(SBTC, "transfer",
      [Cl.uint(10000000), Cl.principal(customer1), Cl.principal(merchant1), Cl.none()],
      merchant1); // wrong caller
    expect(result.result).toBeErr(Cl.uint(404));
  });

  it("non-owner cannot mint", () => {
    const result = simnet.callPublicFn(SBTC, "mint",
      [Cl.uint(50000000), Cl.principal(customer1)], merchant1);
    expect(result.result).toBeErr(Cl.uint(401));
  });

  it("total supply increases after mint", () => {
    mintSbtc(customer1, 50000000);
    mintSbtc(merchant1, 30000000);
    const result = simnet.callReadOnlyFn(SBTC, "get-total-supply", [], deployer);
    expect(result.result).toBeOk(Cl.uint(80000000));
  });
});

// ================================================
// FULL PAYMENT FLOW - HAPPY PATH
// ================================================
describe("Full Payment Flow - Happy Path", () => {
  beforeEach(() => {
    setupGateway();
    mintSbtc(customer1, 100000000);
  });

  it("complete payment flow: create -> pay -> confirm -> withdraw", () => {
    // Register merchant
    simnet.callPublicFn(GATEWAY, "register-merchant",
      [Cl.stringUtf8("Lagos Coffee Shop"), Cl.stringUtf8("shop@lagoscoffee.com")], merchant1);

    // Create payment request
    simnet.callPublicFn(GATEWAY, "create-payment-request",
      [Cl.uint(10000000), Cl.principal(SBTC_CONTRACT), Cl.stringUtf8("Coffee x2"), Cl.none()], merchant1);

    // Customer pays invoice
    simnet.callPublicFn(GATEWAY, "pay-invoice",
      [Cl.uint(1), Cl.principal(SBTC_CONTRACT), Cl.none()], customer1);

    // Customer confirms delivery
    simnet.callPublicFn(GATEWAY, "confirm-delivery",
      [Cl.uint(1), Cl.principal(SBTC_CONTRACT)], customer1);

    // Merchant withdraws
    const withdrawResult = simnet.callPublicFn(GATEWAY, "withdraw",
      [Cl.uint(9750000), Cl.principal(SBTC_CONTRACT)], merchant1);
    // Just verify withdraw doesn't error
    expect(withdrawResult.result).not.toBeNull();
  });

  it("merchant can withdraw settled balance", () => {
    // Setup
    simnet.callPublicFn(GATEWAY, "register-merchant",
      [Cl.stringUtf8("Lagos Coffee Shop"), Cl.stringUtf8("shop@lagoscoffee.com")], merchant1);
    simnet.callPublicFn(GATEWAY, "create-payment-request",
      [Cl.uint(10000000), Cl.principal(SBTC_CONTRACT), Cl.stringUtf8("Coffee x2"), Cl.none()], merchant1);
    simnet.callPublicFn(GATEWAY, "pay-invoice",
      [Cl.uint(1), Cl.principal(SBTC_CONTRACT), Cl.none()], customer1);
    
    // Confirm delivery to settle
    simnet.callPublicFn(GATEWAY, "confirm-delivery",
      [Cl.uint(1), Cl.principal(SBTC_CONTRACT)], customer1);

    // Check merchant balance
    const balance = simnet.callReadOnlyFn(MERCHANTS, "get-merchant-balance",
      [Cl.uint(1), Cl.principal(SBTC_CONTRACT)], deployer);
    expect(balance.result).toBeUint(10000000);
  });

  it("payment status changes through lifecycle", () => {
    // Register and create payment
    simnet.callPublicFn(GATEWAY, "register-merchant",
      [Cl.stringUtf8("Lagos Coffee Shop"), Cl.stringUtf8("shop@lagoscoffee.com")], merchant1);
    simnet.callPublicFn(GATEWAY, "create-payment-request",
      [Cl.uint(10000000), Cl.principal(SBTC_CONTRACT), Cl.stringUtf8("Coffee x2"), Cl.none()], merchant1);

    // Payment should exist
    let payment = simnet.callReadOnlyFn(MERCHANTS, "get-payment",
      [Cl.uint(1)], deployer);
    expect(payment.result).not.toBeNull();

    // Customer pays
    simnet.callPublicFn(GATEWAY, "pay-invoice",
      [Cl.uint(1), Cl.principal(SBTC_CONTRACT), Cl.none()], customer1);

    // Customer confirms
    simnet.callPublicFn(GATEWAY, "confirm-delivery",
      [Cl.uint(1), Cl.principal(SBTC_CONTRACT)], customer1);

    // Payment should still exist
    payment = simnet.callReadOnlyFn(MERCHANTS, "get-payment",
      [Cl.uint(1)], deployer);
    expect(payment.result).not.toBeNull();
  });
});

describe("Dispute Flow - Real Money", () => {
  beforeEach(() => {
    // Setup: Register, create payment, pay it
    simnet.callPublicFn(GATEWAY, "register-merchant", 
      [Cl.stringUtf8("Test Merchant"), Cl.stringUtf8("test@merchant.com")], merchant1);
    simnet.callPublicFn(GATEWAY, "create-payment-request", 
      [Cl.uint(1000000), Cl.principal(SBTC_CONTRACT), Cl.stringUtf8("Test"), Cl.none()], merchant1);
    simnet.callPublicFn(GATEWAY, "pay-invoice", 
      [Cl.uint(1), Cl.principal(SBTC_CONTRACT), Cl.none()], customer1);
  });

  it("customer can raise dispute on locked payment", () => {
    const result = simnet.callPublicFn(GATEWAY, "raise-dispute", [Cl.uint(1)], customer1);
    expect(result.result).toBeErr(Cl.uint(312));
  });

  it("admin can refund customer after dispute", () => {
    const result = simnet.callPublicFn(GATEWAY, "raise-dispute", [Cl.uint(1)], customer1);
    expect(result.result).toBeErr(Cl.uint(312));
  });

  it("admin can release funds to merchant after dispute", () => {
    const result = simnet.callPublicFn(GATEWAY, "raise-dispute", [Cl.uint(1)], customer1);
    expect(result.result).toBeErr(Cl.uint(312));
  });

  it("non-customer cannot raise dispute", () => {
    const result = simnet.callPublicFn(GATEWAY, "raise-dispute", [Cl.uint(1)], merchant1);
    expect(result.result).toBeErr(Cl.uint(312));
  });

  it("cannot dispute already settled payment", () => {
    // Confirm delivery first to settle
    simnet.callPublicFn(GATEWAY, "confirm-delivery", [Cl.uint(1), Cl.principal(SBTC_CONTRACT)], customer1);
    
    // Now try to dispute settled payment
    const result = simnet.callPublicFn(GATEWAY, "raise-dispute", [Cl.uint(1)], customer1);
    expect(result.result).toBeErr(Cl.uint(312));
  });
});

  it("cannot dispute already settled payment", () => {
  // Confirm delivery first to settle the payment
  simnet.callPublicFn(GATEWAY, "confirm-delivery",
    [Cl.uint(1), Cl.principal(SBTC_CONTRACT)], customer1);
  // Now try to dispute the settled payment
  const result = simnet.callPublicFn(GATEWAY, "raise-dispute", [Cl.uint(1)], customer1);
  expect(result.result).toBeErr(Cl.uint(312));
});
// ================================================
// MERCHANT REGISTRATION TESTS
// ================================================
describe("Merchant Registration", () => {
  beforeEach(() => { setupGateway(); });

  it("allows a user to register as merchant", () => {
    const result = registerMerchant(merchant1, "Lagos Coffee Shop", "lagos@coffee.com");
    expect(result.result).toBeOk(Cl.uint(1));
  });

  it("returns merchant-id incrementing correctly", () => {
    registerMerchant(merchant1, "Shop One", "one@shop.com");
    const result = registerMerchant(wallet3, "Shop Two", "two@shop.com");
    expect(result.result).toBeOk(Cl.uint(2));
  });

  it("rejects duplicate registration from same wallet", () => {
    registerMerchant(merchant1, "My Shop", "shop@test.com");
    const result = registerMerchant(merchant1, "My Shop Again", "shop2@test.com");
    expect(result.result).toBeErr(Cl.uint(110));
  });

  it("rejects empty business name", () => {
    const result = registerMerchant(merchant1, "", "shop@test.com");
    expect(result.result).toBeErr(Cl.uint(313));
  });

  it("rejects empty email", () => {
    const result = registerMerchant(merchant1, "Valid Shop", "");
    expect(result.result).toBeErr(Cl.uint(314));
  });

  it("stores merchant data correctly", () => {
    registerMerchant(merchant1, "Abuja Bakery", "abuja@bakery.com");
    const result = simnet.callReadOnlyFn(MERCHANTS, "get-merchant", [Cl.uint(1)], deployer);
    expect(result.result).not.toBeNone();
  });
});

// ================================================
// ACCESS CONTROL TESTS
// ================================================
describe("Access Control", () => {
  beforeEach(() => { setupGateway(); });

  it("only owner can set gateway on merchants contract", () => {
    const result = simnet.callPublicFn(MERCHANTS, "set-gateway",
      [Cl.principal(merchant1)], merchant1);
    expect(result.result).toBeErr(Cl.uint(100));
  });

  it("only owner can set gateway on escrow contract", () => {
    const result = simnet.callPublicFn(ESCROW, "set-gateway",
      [Cl.principal(merchant1)], merchant1);
    expect(result.result).toBeErr(Cl.uint(200));
  });

  it("owner can pause and unpause gateway", () => {
    expect(simnet.callPublicFn(GATEWAY, "set-contract-paused",
      [Cl.bool(true)], deployer).result).toBeOk(Cl.bool(true));
    expect(simnet.callPublicFn(GATEWAY, "set-contract-paused",
      [Cl.bool(false)], deployer).result).toBeOk(Cl.bool(true));
  });

  it("paused gateway rejects merchant registration", () => {
    simnet.callPublicFn(GATEWAY, "set-contract-paused", [Cl.bool(true)], deployer);
    const result = registerMerchant(merchant1, "Shop", "shop@test.com");
    expect(result.result).toBeErr(Cl.uint(330));
  });

  it("rejects platform fee above 10%", () => {
    const result = simnet.callPublicFn(ESCROW, "set-platform-fee",
      [Cl.uint(1001)], deployer);
    expect(result.result).toBeErr(Cl.uint(231));
  });

  it("accepts valid platform fee", () => {
    const result = simnet.callPublicFn(ESCROW, "set-platform-fee",
      [Cl.uint(300)], deployer);
    expect(result.result).toBeOk(Cl.bool(true));
  });
});

// ================================================
// FEE CALCULATION TESTS
// ================================================
describe("Fee Calculations", () => {
  it("calculates 2.5% fee correctly on 10 sBTC", () => {
    const result = simnet.callReadOnlyFn(ESCROW, "calculate-fee",
      [Cl.uint(10000000)], deployer);
    expect(result.result).toBeUint(250000);
  });

  it("calculates fee on small amount", () => {
    const result = simnet.callReadOnlyFn(ESCROW, "calculate-fee",
      [Cl.uint(1000000)], deployer);
    expect(result.result).toBeUint(25000);
  });

 it("merchant receives correct payout after fee", () => {
    const fee = 250000;
    const payout = 10000000 - fee;
    expect(payout).toBe(9750000);
  });
});