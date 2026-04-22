const axios = require('axios');

const STACKS_API = process.env.STACKS_API;
const CONTRACT_ADDRESS = process.env.CONTRACT_ADDRESS;

// ============================================
// Store pending confirmations in memory
// In production this would be a database
// ============================================
const pendingConfirmations = new Map();

function generateCode(paymentId) {
  // Generate a 6-digit confirmation code
  // Tied to payment ID for verification
  const code = Math.floor(100000 + Math.random() * 900000).toString();
  const expiry = Date.now() + (30 * 60 * 1000); // 30 minutes

  pendingConfirmations.set(code, {
    paymentId,
    expiry,
    used: false
  });

  console.log(`Generated code ${code} for payment ${paymentId}`);
  return code;
}

function verifyCode(code) {
  // Check if code exists, is not expired, and not used
  const confirmation = pendingConfirmations.get(code);

  if (!confirmation) {
    return { valid: false, reason: 'Code not found' };
  }

  if (Date.now() > confirmation.expiry) {
    pendingConfirmations.delete(code);
    return { valid: false, reason: 'Code expired' };
  }

  if (confirmation.used) {
    return { valid: false, reason: 'Code already used' };
  }

  // Mark as used
  confirmation.used = true;
  return { valid: true, paymentId: confirmation.paymentId };
}

async function getPaymentInfo(paymentId) {
  // Query payment status from Stacks testnet
  try {
    const url = `${STACKS_API}/v2/contracts/call-read/${CONTRACT_ADDRESS}/stacksbit-gateway/get-payment-info`;
    const response = await axios.post(url, {
      sender: CONTRACT_ADDRESS,
      arguments: [`0x${paymentId.toString(16).padStart(8, '0')}`]
    });
    return response.data;
  } catch (error) {
    console.error('Error fetching payment:', error.message);
    return null;
  }
}

async function agentConfirm(paymentId, agentCode, confirmation) {
  // Trusted agent confirms delivery
  // In production: verify agent code against database
  // For now: accept any agent with correct secret

  const secret = process.env.CONFIRMATION_SECRET;

  if (agentCode !== secret) {
    return { success: false, message: 'Invalid agent code' };
  }

  console.log(`Agent confirmed payment ${paymentId}: ${confirmation}`);

  return {
    success: true,
    paymentId,
    confirmation,
    message: 'Agent confirmation recorded',
    timestamp: new Date().toISOString()
  };
}

module.exports = {
  generateCode,
  verifyCode,
  getPaymentInfo,
  agentConfirm
};