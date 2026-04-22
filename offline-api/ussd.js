const blockchain = require('./blockchain');

// ============================================
// USSD Session Storage
// Tracks where each user is in the menu flow
// ============================================
const sessions = new Map();

async function handleUSSD(sessionId, serviceCode, phoneNumber, text) {
  // text contains the full input chain
  // e.g. "" = first call, "1" = pressed 1, "1*123456" = pressed 1 then entered 123456

  const inputs = text.split('*').filter(i => i !== '');
  const level = inputs.length;

  console.log(`USSD level ${level}, inputs: ${JSON.stringify(inputs)}`);

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
  // Level 1 -- Handle main menu selection
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
      return `END StacksBit Help
For support contact:
rogersterkaa@gmail.com
Or visit: github.com/rogersterkaa/StacksBit`;
    }

    if (choice === '0') {
      return `END Thank you for using StacksBit!`;
    }

    return `CON Invalid option. Please try again.

1. Confirm Delivery
2. Check Payment Status
0. Exit`;
  }

  // ============================================
  // Level 2 -- Handle payment ID entry
  // ============================================
  if (level === 2) {
    const choice = inputs[0];
    const paymentId = inputs[1];

    // Validate payment ID is a number
    if (isNaN(paymentId)) {
      return `END Invalid Payment ID.
Please check your ID and try again.`;
    }

    if (choice === '1') {
      // Confirm delivery flow
      // Generate confirmation code and store in session
      sessions.set(sessionId, {
        paymentId,
        phoneNumber,
        action: 'confirm'
      });

      return `CON Payment ID: ${paymentId}
Enter your 6-digit confirmation code:
(Check your SMS for the code)`;
    }

    if (choice === '2') {
      // Check payment status
      const payment = await blockchain.getPaymentInfo(parseInt(paymentId));

      if (!payment) {
        return `END Payment #${paymentId} not found.
Please check your Payment ID.`;
      }

      return `END Payment #${paymentId} Status:
${payment.result || 'Unable to fetch status'}

For help: rogersterkaa@gmail.com`;
    }
  }

  // ============================================
  // Level 3 -- Handle confirmation code entry
  // ============================================
  if (level === 3) {
    const code = inputs[2];
    const session = sessions.get(sessionId);

    if (!session) {
      return `END Session expired.
Please start again by dialing *384*paymentID#`;
    }

    const verification = blockchain.verifyCode(code);

    if (!verification.valid) {
      return `END Confirmation failed.
Reason: ${verification.reason}

Please request a new code and try again.`;
    }

    // Success!
    sessions.delete(sessionId);

    console.log(`Payment ${session.paymentId} confirmed via USSD by ${phoneNumber}`);

    return `END Delivery Confirmed!
Payment #${session.paymentId} has been confirmed.
Funds will be released to your account shortly.

Thank you for using StacksBit!`;
  }

  return `END Something went wrong.
Please try again.`;
}

module.exports = { handleUSSD };