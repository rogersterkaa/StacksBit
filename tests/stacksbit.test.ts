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

function setupGateway() {
  const gw = `${deployer}.${GATEWAY}`;
  simnet.callPublicFn(MERCHANTS, "set-gateway", [Cl.principal(gw)], deployer);
  simnet.callPublicFn(ESCROW, "set-gateway", [Cl.principal(gw)], deployer);
}

function registerMerchant(wallet: string, name: string, email: string) {
  return simnet.callPublicFn(
    GATEWAY, "register-merchant",
    [Cl.stringUtf8(name), Cl.stringUtf8(email)],
    wallet
  );
}

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

describe("Payment Requests", () => {
  beforeEach(() => {
    setupGateway();
    registerMerchant(merchant1, "Test Shop", "test@shop.com");
  });

  it("merchant can create a payment request", () => {
    const result = simnet.callPublicFn(
      GATEWAY, "create-payment-request",
      [Cl.uint(1000000), Cl.principal(`${deployer}.sbtc`), Cl.stringUtf8("Coffee"), Cl.none()],
      merchant1
    );
    expect(result.result).toBeOk(Cl.uint(1));
  });

  it("rejects payment request with zero amount", () => {
    const result = simnet.callPublicFn(
      GATEWAY, "create-payment-request",
      [Cl.uint(0), Cl.principal(`${deployer}.sbtc`), Cl.stringUtf8("Zero"), Cl.none()],
      merchant1
    );
    expect(result.result).toBeErr(Cl.uint(310));
  });

  it("rejects payment request from unregistered user", () => {
    const result = simnet.callPublicFn(
      GATEWAY, "create-payment-request",
      [Cl.uint(500000), Cl.principal(`${deployer}.sbtc`), Cl.stringUtf8("Unauth"), Cl.none()],
      customer1
    );
    expect(result.result).toBeErr(Cl.uint(301));
  });

  it("payment request increments payment-id", () => {
    simnet.callPublicFn(GATEWAY, "create-payment-request",
      [Cl.uint(1000000), Cl.principal(`${deployer}.sbtc`), Cl.stringUtf8("First"), Cl.none()], merchant1);
    const result = simnet.callPublicFn(GATEWAY, "create-payment-request",
      [Cl.uint(2000000), Cl.principal(`${deployer}.sbtc`), Cl.stringUtf8("Second"), Cl.none()], merchant1);
    expect(result.result).toBeOk(Cl.uint(2));
  });
});

describe("Escrow - lock-funds", () => {
  beforeEach(() => { setupGateway(); });

  it("only gateway can lock funds", () => {
    const result = simnet.callPublicFn(
      ESCROW, "lock-funds",
      [Cl.uint(1), Cl.principal(`${deployer}.sbtc`), Cl.uint(1000000),
       Cl.principal(customer1), Cl.principal(merchant1), Cl.none()],
      customer1
    );
    expect(result.result).toBeErr(Cl.uint(201));
  });

  it("rejects zero amount when called by non-gateway", () => {
    const result = simnet.callPublicFn(
      ESCROW, "lock-funds",
      [Cl.uint(1), Cl.principal(`${deployer}.sbtc`), Cl.uint(0),
       Cl.principal(customer1), Cl.principal(merchant1), Cl.none()],
      customer1
    );
    expect(result.result).toBeErr(Cl.uint(201));
  });
});

describe("Dispute Resolution", () => {
  beforeEach(() => { setupGateway(); });

  it("only gateway can flag a dispute - non-existent payment returns u210", () => {
    const result = simnet.callPublicFn(ESCROW, "flag-dispute", [Cl.uint(999)], customer1);
    expect(result.result).toBeErr(Cl.uint(210));
  });

  it("cannot dispute non-existent payment", () => {
    const result = simnet.callPublicFn(ESCROW, "flag-dispute", [Cl.uint(999)], deployer);
    expect(result.result).toBeErr(Cl.uint(210));
  });
});

describe("Merchant Storage", () => {
  beforeEach(() => {
    setupGateway();
    registerMerchant(merchant1, "Kano Textiles", "kano@textiles.com");
  });

  it("can retrieve merchant by id", () => {
    const result = simnet.callReadOnlyFn(MERCHANTS, "get-merchant", [Cl.uint(1)], deployer);
    expect(result.result).not.toBeNone();
  });

  it("can retrieve merchant-id by owner", () => {
    const result = simnet.callReadOnlyFn(MERCHANTS, "get-merchant-id-by-owner",
      [Cl.principal(merchant1)], deployer);
    expect(result.result).not.toBeNone();
  });

  it("returns none for unregistered merchant", () => {
    const result = simnet.callReadOnlyFn(MERCHANTS, "get-merchant-id-by-owner",
      [Cl.principal(customer1)], deployer);
    expect(result.result).toBeNone();
  });

  it("merchant balance starts at zero", () => {
    const result = simnet.callReadOnlyFn(MERCHANTS, "get-merchant-balance",
      [Cl.uint(1), Cl.principal(`${deployer}.sbtc`)], deployer);
    expect(result.result).toBeUint(0);
  });
});

describe("Access Control", () => {
  beforeEach(() => { setupGateway(); });

  it("only owner can set gateway on merchants contract", () => {
    const result = simnet.callPublicFn(MERCHANTS, "set-gateway", [Cl.principal(merchant1)], merchant1);
    expect(result.result).toBeErr(Cl.uint(100));
  });

  it("only owner can set gateway on escrow contract", () => {
    const result = simnet.callPublicFn(ESCROW, "set-gateway", [Cl.principal(merchant1)], merchant1);
    expect(result.result).toBeErr(Cl.uint(200));
  });

  it("only owner can pause merchants contract", () => {
    const result = simnet.callPublicFn(MERCHANTS, "set-contract-paused", [Cl.bool(true)], merchant1);
    expect(result.result).toBeErr(Cl.uint(100));
  });

  it("owner can pause and unpause gateway", () => {
    expect(simnet.callPublicFn(GATEWAY, "set-contract-paused", [Cl.bool(true)], deployer).result).toBeOk(Cl.bool(true));
    expect(simnet.callPublicFn(GATEWAY, "set-contract-paused", [Cl.bool(false)], deployer).result).toBeOk(Cl.bool(true));
  });

  it("paused gateway rejects merchant registration", () => {
    simnet.callPublicFn(GATEWAY, "set-contract-paused", [Cl.bool(true)], deployer);
    const result = registerMerchant(merchant1, "Shop", "shop@test.com");
    expect(result.result).toBeErr(Cl.uint(330));
  });

  it("only owner can set platform fee on escrow", () => {
    const result = simnet.callPublicFn(ESCROW, "set-platform-fee", [Cl.uint(300)], merchant1);
    expect(result.result).toBeErr(Cl.uint(200));
  });

  it("rejects platform fee above 10%", () => {
    const result = simnet.callPublicFn(ESCROW, "set-platform-fee", [Cl.uint(1001)], deployer);
    expect(result.result).toBeErr(Cl.uint(231));
  });

  it("accepts valid platform fee", () => {
    const result = simnet.callPublicFn(ESCROW, "set-platform-fee", [Cl.uint(300)], deployer);
    expect(result.result).toBeOk(Cl.bool(true));
  });
});

describe("Fee Calculations", () => {
  it("calculates 2.5% fee correctly", () => {
    const result = simnet.callReadOnlyFn(ESCROW, "calculate-fee", [Cl.uint(10000000)], deployer);
    expect(result.result).toBeUint(250000);
  });

  it("calculates fee on small amount", () => {
    const result = simnet.callReadOnlyFn(ESCROW, "calculate-fee", [Cl.uint(1000000)], deployer);
    expect(result.result).toBeUint(25000);
  });
});
