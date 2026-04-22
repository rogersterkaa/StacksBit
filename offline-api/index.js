const express = require('express');
const cors = require('cors');
require('dotenv').config();

const app = express();
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Import handlers
const smsHandler = require('./sms');
const ussdHandler = require('./ussd');
const blockchainHandler = require('./blockchain');

// ============================================
// Health Check
// ============================================
app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    service: 'StacksBit Offline Confirmation API',
    network: 'testnet',
    features: ['SMS', 'USSD'],
    timestamp: new Date().toISOString()
  });
});

// ============================================
// SMS Routes
// ============================================

// Africa's Talking calls this when merchant replies to SMS
app.post('/sms/incoming', async (req, res) => {
  try {
    const { from, text } = req.body;
    console.log(`SMS received from ${from}: ${text}`);
    const result = await smsHandler.handleIncomingSMS(from, text);
    res.json(result);
  } catch (error) {
    console.error('SMS error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Merchant requests SMS confirmation code
app.post('/sms/send-confirmation', async (req, res) => {
  try {
    const { phoneNumber, paymentId } = req.body;
    const result = await smsHandler.sendConfirmationCode(
      phoneNumber,
      paymentId
    );
    res.json(result);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// ============================================
// USSD Routes
// ============================================

// Africa's Talking calls this for every USSD interaction
app.post('/ussd', async (req, res) => {
  try {
    const {
      sessionId,
      serviceCode,
      phoneNumber,
      text
    } = req.body;

    console.log(`USSD session ${sessionId} from ${phoneNumber}: ${text}`);

    const response = await ussdHandler.handleUSSD(
      sessionId,
      serviceCode,
      phoneNumber,
      text
    );

    // Africa's Talking expects plain text response
    res.set('Content-Type', 'text/plain');
    res.send(response);
  } catch (error) {
    console.error('USSD error:', error);
    res.set('Content-Type', 'text/plain');
    res.send('END Sorry, an error occurred. Please try again.');
  }
});

// ============================================
// Agent Routes
// ============================================

// Trusted agent confirms delivery on behalf of merchant
app.post('/agent/confirm', async (req, res) => {
  try {
    const { paymentId, agentCode, confirmation } = req.body;
    const result = await blockchainHandler.agentConfirm(
      paymentId,
      agentCode,
      confirmation
    );
    res.json(result);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// ============================================
// Start Server
// ============================================
const PORT = process.env.PORT || 3001;
app.listen(PORT, () => {
  console.log(`StacksBit Offline API running on http://localhost:${PORT}`);
  console.log(`Health: http://localhost:${PORT}/health`);
  console.log(`SMS webhook: http://localhost:${PORT}/sms/incoming`);
  console.log(`USSD webhook: http://localhost:${PORT}/ussd`);
});