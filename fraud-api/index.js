const express = require('express');
const cors = require('cors');
const axios = require('axios');
const { principalCV, serializeCV } = require('@stacks/transactions');

const app = express();
app.use(cors());
app.use(express.json());

const TESTNET_API = 'https://api.testnet.hiro.so';
const CONTRACT_ADDRESS = 'ST3GTDAAVRPKHCC45FFW0540MPTDHGWWRMB5DS4Q0';
const FRAUD_CONTRACT = 'stacksbit-fraud';

// ============================================
// Helper: Call read-only contract function
// ============================================
async function callReadOnly(contractName, functionName, args = []) {
  const url = `${TESTNET_API}/v2/contracts/call-read/${CONTRACT_ADDRESS}/${contractName}/${functionName}`;
  const response = await axios.post(url, {
    sender: CONTRACT_ADDRESS,
    arguments: args
  });
  return response.data;
}

// ============================================
// Helper: Encode principal for Clarity
// ============================================
function encodePrincipal(address) {
  return '0x' + Buffer.from(
    serializeCV(principalCV(address))
  ).toString('hex');
}

// ============================================
// GET /health
// ============================================
app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    service: 'StacksBit Fraud Detection API',
    network: 'testnet',
    contractAddress: CONTRACT_ADDRESS,
    timestamp: new Date().toISOString()
  });
});

// ============================================
// GET /risk-score/:merchantAddress
// ============================================
app.get('/risk-score/:merchantAddress', async (req, res) => {
  try {
    const { merchantAddress } = req.params;

    const url = `${TESTNET_API}/v2/contracts/call-read/${CONTRACT_ADDRESS}/${FRAUD_CONTRACT}/get-risk-score`;
    
    const response = await axios.post(url, {
      sender: CONTRACT_ADDRESS,
      arguments: [`0x051a${Buffer.from(merchantAddress.slice(1), 'ascii').toString('hex')}`]
    });

    const result = response.data;
    const raw = result.result || '';
const score = raw.startsWith('0x') ? parseInt(raw.slice(-8), 16) : 0;
    let riskLevel = 'low';
    let color = 'green';
    let message = 'Safe merchant';

    if (score >= 70) {
      riskLevel = 'high';
      color = 'red';
      message = 'High risk merchant — proceed with caution';
    } else if (score >= 40) {
      riskLevel = 'medium';
      color = 'yellow';
      message = 'Medium risk — verify merchant before paying';
    }

    res.json({
      merchantAddress,
      riskScore: score,
      riskLevel,
      color,
      message,
      timestamp: new Date().toISOString()
    });

  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// ============================================
// GET /merchant-reputation/:merchantAddress
// ============================================
app.get('/merchant-reputation/:merchantAddress', async (req, res) => {
  try {
    const { merchantAddress } = req.params;

    const [reputationResult, blacklistResult] = await Promise.all([
      callReadOnly(FRAUD_CONTRACT, 'get-merchant-reputation', [
        encodePrincipal(merchantAddress)
      ]),
      callReadOnly(FRAUD_CONTRACT, 'is-blacklisted', [
        encodePrincipal(merchantAddress)
      ])
    ]);

    res.json({
      merchantAddress,
      reputation: reputationResult.result,
      isBlacklisted: blacklistResult.result === '0x03',
      timestamp: new Date().toISOString()
    });

  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// ============================================
// Start server
// ============================================
const PORT = 3000;
app.listen(PORT, () => {
  console.log(`StacksBit Fraud API running on http://localhost:${PORT}`);
  console.log(`Health check: http://localhost:${PORT}/health`);
  console.log(`Risk score: http://localhost:${PORT}/risk-score/:address`);
});