const AfricasTalking = require('africastalking');
const blockchain = require('./blockchain');

// Initialize Africa's Talking
const AT = AfricasTalking({
  username: process.env.AT_USERNAME,
  apiKey: process.env.AT_API_KEY
});

const sms = AT.SMS;

async function sendConfirmationCode(phoneNumber, paymentId) {
  // Generate a confirmation code for this payment
  const code = blockchain.generateCode(paymentId);

  const message = `StacksBit: Your delivery confirmation code for Payment #${paymentId} is: ${code}. Reply with this code to confirm delivery. Valid for 30 minutes.`;

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
  // Merchant replies with their confirmation code
  const code = text.trim().toUpperCase();

  console.log(`Processing SMS confirmation: ${code} from ${from}`);

  const verification = blockchain.verifyCode(code);

  if (!verification.valid) {
    // Send failure SMS back to merchant
    await sms.send({
      to: [from],
      message: `StacksBit: Confirmation failed. ${verification.reason}. Please request a new code.`,
      from: 'StacksBit'
    });

    return {
      success: false,
      reason: verification.reason
    };
  }

  // Code is valid -- confirm delivery
  console.log(`Payment ${verification.paymentId} confirmed via SMS by ${from}`);

  // Send success SMS back to merchant
  await sms.send({
    to: [from],
    message: `StacksBit: Payment #${verification.paymentId} delivery confirmed! Funds will be released to your account shortly.`,
    from: 'StacksBit'
  });

  return {
    success: true,
    paymentId: verification.paymentId,
    confirmedBy: from,
    method: 'SMS',
    timestamp: new Date().toISOString()
  };
}

module.exports = {
  sendConfirmationCode,
  handleIncomingSMS
};