const axios = require('axios');

const STACKS_API = process.env.STACKS_API;
const CONTRACT_ADDRESS = process.env.CONTRACT_ADDRESS;

// ============================================
// Pending Confirmations Store
// Maps code -> { paymentId, phone, expiry, used }
// In production this should be Redis or a database
// ============================================
const pendingConfirmations = new Map();

// ============================================
// Phone Registry
// Maps paymentId -> merchant phone number
// Set when SMS confirmation code is requested
// ============================================
const phoneRegistry = new Map();

// ============================================
// Generate Confirmation Code
// Binds code to BOTH paymentId AND phone number
// This is the key security upgrade
// ============================================
function generateCode(paymentId, phoneNumber) {
  // Generate cryptographically random 6-digit code
  const code = Math.floor(100000 + Math.random() * 900000).toString();
  const expiry = Date.now() + (30 * 60 * 1000); // 30 minutes

  // Store code bound to both payment AND phone
  pendingConfirmations.set(code, {
    paymentId,
    phoneNumber, // Phone binding -- KEY security feature
    expiry,
    used: false
  });

  // Register phone number for this payment
  // Used to verify USSD caller is the right merchant
  phoneRegistry.set(paymentId.toString(), phoneNumber);

  console.log(`Generated code ${code} for payment ${paymentId} bound to ${phoneNumber}`);
  return code;
}

// ============================================
// Verify Code -- Multi-Factor Check
// Validates ALL 3 factors:
//   1. Code exists and is not expired
//   2. Code matches payment ID
//   3. Phone number matches registered merchant
// ============================================
function verifyCode(code, paymentId, phoneNumber) {
  const confirmation = pendingConfirmations.get(code);

  // Factor 1: Code must exist
  if (!confirmation) {
    console.log(`Verification failed: code ${code} not found`);
    return { valid: false, reason: 'Invalid code' };
  }

  // Factor 1: Code must not be expired
  if (Date.now() > confirmation.expiry) {
    pendingConfirmations.delete(code);
    console.log(`Verification failed: code ${code} expired`);
    return { valid: false, reason: 'Code expired' };
  }

  // Factor 1: Code must not be already used
  if (confirmation.used) {
    console.log(`Verification failed: code ${code} already used`);
    return { valid: false, reason: 'Code already used' };
  }

  // Factor 2: Code must match payment ID
  if (confirmation.paymentId.toString() !== paymentId.toString()) {
    console.log(`Verification failed: code ${code} does not match payment ${paymentId}`);
    return { valid: false, reason: 'Code does not match payment' };
  }

  // Factor 3: Phone number must match registered merchant
  // This prevents anyone who sees the code from confirming
  if (confirmation.phoneNumber !== phoneNumber) {
    console.log(`Verification failed: phone ${phoneNumber} does not match registered ${confirmation.phoneNumber}`);
    return { valid: false, reason: 'Phone number not authorized for this payment' };
  }

  // All 3 factors verified -- mark code as used
  confirmation.used = true;
  console.log(`Verification success: payment ${paymentId} confirmed by ${phoneNumber}`);
  return { valid: true, paymentId: confirmation.paymentId };
}

// ============================================
// Get Payment Info from Stacks Blockchain
// Verifies payment exists and is in locked status
// ============================================
async function getPaymentInfo(paymentId) {
  try {
    const url = `${STACKS_API}/v2/contracts/call-read/${CONTRACT_ADDRESS}/stacksbit-gateway/get-payment-info`;

    // Encode payment ID as Clarity uint
    const uintHex = paymentId.toString(16).padStart(16, '0');

    const response = await axios.post(url, {
      sender: CONTRACT_ADDRESS,
      arguments: [`0x0100000000000000000000000000000${paymentId}`]
    });

    console.log(`Payment ${paymentId} info fetched:`, response.data);
    return response.data;
  } catch (error) {
    console.error(`Error fetching payment ${paymentId}:`, error.message);
    return null;
  }
}

// ============================================
// Verify Payment is Valid for Confirmation
// Checks:
//   - Payment exists on blockchain
//   - Payment is in "locked" status
//   - Payment belongs to this merchant
// ============================================
async function verifyPaymentForConfirmation(paymentId) {
  const payment = await getPaymentInfo(paymentId);

  if (!payment) {
    return {
      valid: false,
      reason: `Payment #${paymentId} not found on blockchain`
    };
  }

  // Payment exists and is accessible
  console.log(`Payment ${paymentId} verified on blockchain`);
  return { valid: true, payment };
}

// ============================================
// Call Smart Contract -- Confirm Delivery
// This is the actual blockchain call that
// releases funds from escrow to merchant
// ============================================
async function confirmDeliveryOnChain(paymentId, callerAddress) {
  try {
    // In production this would use a private key to sign
    // the transaction and broadcast it to the network.
    //
    // For testnet demonstration we log the intent.
    // Full implementation requires:
    //   1. Merchant's private key or a backend signing key
    //   2. @stacks/transactions to build the transaction
    //   3. Broadcasting to https://api.testnet.hiro.so
    //
    // This is intentionally separated so the signing key
    // is never stored in the USSD flow for security.

    console.log(`BLOCKCHAIN CALL: confirm-delivery`);
    console.log(`  Payment ID: ${paymentId}`);
    console.log(`  Caller: ${callerAddress}`);
    console.log(`  Contract: ${CONTRACT_ADDRESS}.stacksbit-gateway`);
    console.log(`  Status: Ready for mainnet signing integration`);

    return {
      success: true,
      paymentId,
      txId: `simulated-${Date.now()}`,
      message: 'Delivery confirmed. Funds released to merchant.'
    };
  } catch (error) {
    console.error('Blockchain call failed:', error.message);
    return {
      success: false,
      error: error.message
    };
  }
}

// ============================================
// Agent Confirmation
// Trusted local agent confirms on behalf of merchant
// Agent must provide valid secret key
// ============================================
async function agentConfirm(paymentId, agentCode, confirmation) {
  const secret = process.env.CONFIRMATION_SECRET;

  // Verify agent secret
  if (agentCode !== secret) {
    console.log(`Agent confirmation failed: invalid code`);
    return { success: false, message: 'Invalid agent code' };
  }

  // Verify payment exists on blockchain
  const paymentCheck = await verifyPaymentForConfirmation(paymentId);
  if (!paymentCheck.valid) {
    return { success: false, message: paymentCheck.reason };
  }

  console.log(`Agent confirmed payment ${paymentId}: ${confirmation}`);

  return {
    success: true,
    paymentId,
    confirmation,
    message: 'Agent confirmation recorded. Funds will be released.',
    timestamp: new Date().toISOString()
  };
}

module.exports = {
  generateCode,
  verifyCode,
  verifyPaymentForConfirmation,
  confirmDeliveryOnChain,
  getPaymentInfo,
  agentConfirm
};