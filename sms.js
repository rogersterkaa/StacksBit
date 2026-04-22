const AfricasTalking = require('africastalking');
const blockchain = require('./blockchain');

// Initialize Africa's Talking
const AT = AfricasTalking({
  username: process.env.AT_USERNAME,
  apiKey: process.env.AT_API_KEY
});

const sms = AT.SMS;

async function sendConfirmationCode(phoneNumber, paymentId) {
  // SECURITY: Verify payment exists before sending code
  const paymentCheck = await blockchain.verifyPaymentForConfirmation(paymentId);

  if (!paymentCheck.valid) {
    return {
      success: false,
      error: paymentCheck.reason
    };
  }

  // Generate code bound to BOTH payment ID AND phone number
  // This is the key security upgrade
  const code = blockchain.generateCode(paymentId, phoneNumber);

  const message = `StacksBit: Delivery confirmation code for Payment #${paymentId}: ${code}. Reply with this code to confirm. Valid 30 mins. Do not share this code.`;

  try {
    const result = await sms.send({
      to: [phoneNumber],
      message: message,
      from: 'StacksBit'
    });

    console.log(`SMS sent to ${phoneNumber} for payment ${paymentId}`);

    return {
      success: true,
      paymentId,
      phoneNumber,
      message: 'Confirmation code sent via SMS'
    };
  } catch (error) {
    console.error('SMS send error:', error);
    return {
      success: false,
      error: error.message
    };
  }
}

async function handleIncomingSMS(from, text) {
  // Extract code and payment ID from SMS reply
  // Expected format: "CODE PAYMENTID" e.g. "357948 1"
  // Or just the code: "357948"
  const parts = text.trim().split(' ');
  const code = parts[0].toUpperCase();
  const paymentId = parts[1] || null;

  console.log(`SMS confirmation: code=${code} paymentId=${paymentId} from=${from}`);

  // SECURITY: Verify ALL 3 factors including phone number
  const verification = blockchain.verifyCode(code, paymentId, from);

  if (!verification.valid) {
    await sms.send({
      to: [from],
      message: `StacksBit: Confirmation failed. ${verification.reason}. Request a new code and try again.`,
      from: 'StacksBit'
    });

    return { success: false, reason: verification.reason };
  }

  // All verified -- call smart contract
  const txResult = await blockchain.confirmDeliveryOnChain(
    verification.paymentId,
    from
  );

  if (!txResult.success) {
    await sms.send({
      to: [from],
      message: `StacksBit: Verification passed but transaction failed. Contact support: rogersterkaa@gmail.com`,
      from: 'StacksBit'
    });
    return { success: false, error: 'Blockchain call failed' };
  }

  // Success!
  await sms.send({
    to: [from],
    message: `StacksBit: Payment #${verification.paymentId} confirmed! Funds released to your account. Tx: ${txResult.txId}`,
    from: 'StacksBit'
  });

  return {
    success: true,
    paymentId: verification.paymentId,
    confirmedBy: from,
    method: 'SMS',
    txId: txResult.txId,
    timestamp: new Date().toISOString()
  };
}

module.exports = {
  sendConfirmationCode,
  handleIncomingSMS
};