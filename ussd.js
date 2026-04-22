const blockchain = require('./blockchain');

// ============================================
// USSD Session Storage
// Tracks menu state per session
// In production use Redis for persistence
// ============================================
const sessions = new Map();

async function handleUSSD(sessionId, serviceCode, phoneNumber, text) {
  const inputs = text.split('*').filter(i => i !== '');
  const level = inputs.length;

  console.log(`USSD: session=${sessionId} phone=${phoneNumber} level=${level} inputs=${JSON.stringify(inputs)}`);

  // ============================================
  // Level 0 -- Main Menu
  // ============================================
  if (level === 0) {
    return `CON Welcome to StacksBit
Bitcoin Payments for African Merchants

1. Confirm Delivery
2. Check Payment Status
3. Get Help
0. Exit`;
  }

  // ============================================
  // Level 1 -- Main menu selection
  // ============================================
  if (level === 1) {
    const choice = inputs[0];

    if (choice === '1') {
      return `CON Confirm Delivery
Enter your Payment ID:`;
    }

    if (choice === '2') {
      return `CON Check Payment Status
Enter your Payment ID:`;
    }

    if (choice === '3') {
      return `END StacksBit Support
Email: rogersterkaa@gmail.com
GitHub: github.com/rogersterkaa/StacksBit`;
    }

    if (choice === '0') {
      return `END Thank you for using StacksBit!`;
    }

    return `CON Invalid option.

1. Confirm Delivery
2. Check Payment Status
0. Exit`;
  }

  // ============================================
  // Level 2 -- Payment ID entered
  // ============================================
  if (level === 2) {
    const choice = inputs[0];
    const paymentId = inputs[1];

    // Validate payment ID is a number
    if (isNaN(paymentId) || paymentId === '') {
      return `END Invalid Payment ID.
Please check and try again.`;
    }

    if (choice === '1') {
      // SECURITY CHECK 1: Verify payment exists on blockchain
      console.log(`Verifying payment ${paymentId} on blockchain...`);
      const paymentCheck = await blockchain.verifyPaymentForConfirmation(paymentId);

      if (!paymentCheck.valid) {
        return `END ${paymentCheck.reason}
Please check your Payment ID.`;
      }

      // SECURITY CHECK 2: Verify phone number is registered
      // for this payment (set when SMS code was requested)
      const registeredPhone = blockchain.phoneRegistry
        ? blockchain.phoneRegistry.get(paymentId.toString())
        : null;

      if (registeredPhone && registeredPhone !== phoneNumber) {
        // Phone number does not match registered merchant
        console.log(`SECURITY: Phone mismatch for payment ${paymentId}`);
        console.log(`  Expected: ${registeredPhone}`);
        console.log(`  Got: ${phoneNumber}`);
        return `END Not authorized.
This payment is registered to a different phone number.
Contact support: rogersterkaa@gmail.com`;
      }

      // Store session for next step
      sessions.set(sessionId, {
        paymentId,
        phoneNumber,
        action: 'confirm',
        timestamp: Date.now()
      });

      return `CON Payment #${paymentId} found.
Enter your 6-digit confirmation code:
(Request code via SMS first)`;
    }

    if (choice === '2') {
      // Check payment status
      const payment = await blockchain.getPaymentInfo(parseInt(paymentId));

      if (!payment) {
        return `END Payment #${paymentId} not found.
Please check your Payment ID.`;
      }

      return `END Payment #${paymentId}
Status: ${payment.result || 'Unable to fetch'}

For help: rogersterkaa@gmail.com`;
    }
  }

  // ============================================
  // Level 3 -- Confirmation code entered
  // ============================================
  if (level === 3) {
    const code = inputs[2];
    const paymentId = inputs[1];
    const session = sessions.get(sessionId);

    if (!session) {
      return `END Session expired.
Please start again.`;
    }

    // SECURITY CHECK: Verify ALL 3 factors
    // 1. Code is valid and not expired
    // 2. Code matches payment ID
    // 3. Phone number matches registered merchant
    console.log(`Verifying code ${code} for payment ${paymentId} from ${phoneNumber}`);
    const verification = blockchain.verifyCode(code, paymentId, phoneNumber);

    if (!verification.valid) {
      console.log(`Verification failed: ${verification.reason}`);
      return `END Confirmation failed.
Reason: ${verification.reason}

Request a new code via SMS and try again.`;
    }

    // All 3 factors verified!
    // Now call the smart contract to release funds
    console.log(`All factors verified. Calling smart contract...`);
    const txResult = await blockchain.confirmDeliveryOnChain(
      paymentId,
      phoneNumber
    );

    // Clean up session
    sessions.delete(sessionId);

    if (!txResult.success) {
      return `END Verification passed but blockchain call failed.
Please contact support: rogersterkaa@gmail.com
Payment ID: ${paymentId}`;
    }

    console.log(`Payment ${paymentId} fully confirmed via USSD by ${phoneNumber}`);

    return `END Delivery Confirmed!
Payment #${paymentId} verified.
Funds released to your account.

Transaction: ${txResult.txId}
Thank you for using StacksBit!`;
  }

  return `END Something went wrong.
Please try again.`;
}

module.exports = { handleUSSD };