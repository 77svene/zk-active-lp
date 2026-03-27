# 🚀 LiquiAgent: ZK-Verified Autonomous Liquidity Provider

> **The first autonomous LP that proves active range management via ZK without revealing price paths to prevent front-running.**

**Hackathon:** [ETHGlobal HackMoney 2026](https://ethglobal.com) - Uniswap Track | **Prize Pool:** $50K+

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-blue.svg)](https://docs.soliditylang.org/)
[![Circom](https://img.shields.io/badge/Circom-2.0.0-orange.svg)](https://github.com/iden3/circom)
[![Node.js](https://img.shields.io/badge/Node.js-20.x-green.svg)](https://nodejs.org/)
[![Hardhat](https://img.shields.io/badge/Hardhat-2.19.0-purple.svg)](https://hardhat.org/)
[![Uniswap V3](https://img.shields.io/badge/Uniswap-V3-black.svg)](https://uniswap.org/)

---

## 🧐 Problem

**Passive Liquidity Provision is Vulnerable.**
Traditional Uniswap V3 liquidity providers face significant challenges:
1.  **MEV & Front-Running:** When active managers rebalance positions, their transactions are visible in the mempool. MEV bots detect these moves and front-run them, eroding LP profits.
2.  **Strategy Leakage:** To prove solvency or performance, LPs often have to reveal trade history or price paths, exposing their alpha to competitors.
3.  **Inefficiency:** Autonomous management requires constant monitoring and gas-heavy transactions, often making active management unprofitable compared to passive holding.

## 💡 Solution

**LiquiAgent introduces Privacy-Preserving Active Management.**
LiquiAgent is an ERC-4626-compliant vault where an autonomous agent manages liquidity positions on Uniswap V3. Unlike standard LPs, LiquiAgent uses a **Circom circuit** to generate a **ZK proof** that the agent has rebalanced within a valid price range without exposing the specific price levels or trade sizes to the public mempool.

### Key Features
*   **🔒 ZK-Verified Range Management:** Proves valid rebalancing actions without revealing price paths.
*   **🤖 Autonomous Operation:** Node.js service monitors on-chain state and executes trades via LI.FI.
*   **🛡️ MEV Resistance:** Hides trade intent until the transaction is finalized, preventing front-running.
*   **📊 Transparent Solvency:** Dashboard allows users to verify agent performance and vault health without compromising strategy privacy.
*   **🔗 Cross-Chain Ready:** Integrates LI.FI for seamless liquidity movement across chains.

---

## 🏗️ Architecture

```text
+---------------------+       +---------------------------+       +---------------------+
|      User           |       |   LiquiAgent Service      |       |   On-Chain Layer    |
| (Dashboard / Vault) |       |   (Node.js Agent)         |       |   (Ethereum/Chain)  |
+---------------------+       +---------------------------+       +---------------------+
          |                               |                               |
          | 1. View Solvency/Perf         | 2. Monitor On-Chain State     |
          |<------------------------------|                               |
          |                               |                               |
          |                               | 3. Detect Rebalance Trigger   |
          |                               |------------------------------>|
          |                               |                               |
          |                               | 4. Generate ZK Proof          |
          |                               | (ActiveRangeProof.circom)     |
          |                               |<------------------------------|
          |                               |                               |
          |                               | 5. Submit Proof + Tx          |
          |                               |------------------------------>|
          |                               |                               |
          | 6. Verify Proof               |                               |
          |<------------------------------|                               |
          |                               |                               |
          | 7. Update Dashboard           |                               |
          |<------------------------------|                               |
          |                               |                               |
+---------------------+       +---------------------------+       +---------------------+
|   public/dashboard.html  |       |   services/AgentService.js  |       |   contracts/          |
|                          |       |                           |       |   AgentVerifier.sol   |
+--------------------------+       +---------------------------+       +---------------------+
```

---

## 🛠️ Tech Stack

| Component | Technology |
| :--- | :--- |
| **Smart Contracts** | Solidity 0.8.20, Hardhat |
| **ZK Circuits** | Circom 2.0.0, SnarkJS |
| **Backend Service** | Node.js 20.x, Express |
| **DEX Integration** | Uniswap V3, LI.FI SDK |
| **Vault Standard** | ERC-4626 |
| **Verification** | AgentVerifier.sol |

---

## 🚀 Setup Instructions

### Prerequisites
*   Node.js v20+
*   npm or yarn
*   Hardhat installed globally or locally
*   Circom compiler installed

### 1. Clone the Repository
```bash
git clone https://github.com/77svene/zk-active-lp
cd zk-active-lp
```

### 2. Install Dependencies
```bash
npm install
```

### 3. Configure Environment
Create a `.env` file in the root directory with the following variables:

```env
# Network Configuration
RPC_URL=https://mainnet.infura.io/v3/YOUR_KEY
PRIVATE_KEY=0xYOUR_PRIVATE_KEY
CHAIN_ID=1

# Circuit Configuration
CIRCUIT_PATH=./circuits/ActiveRangeProof.circom
PROOF_DIR=./proofs

# Agent Configuration
AGENT_SERVICE_PORT=3000
LI_FI_API_KEY=YOUR_LI_FI_KEY
UNISWAP_V3_POOL_ADDRESS=0x...

# Contract Addresses (Post-Deployment)
VAULT_ADDRESS=0x...
VERIFIER_ADDRESS=0x...
CONTROLLER_ADDRESS=0x...
```

### 4. Compile Circuits & Contracts
```bash
# Compile Circom Circuit
npx circom circuits/ActiveRangeProof.circom --r1cs --wasm --sym

# Compile Hardhat Contracts
npx hardhat compile
```

### 5. Deploy Contracts
```bash
npx hardhat run scripts/deploy.js --network localhost
```
*(Update `.env` with deployed addresses after deployment)*

### 6. Start the Agent Service
```bash
npm start
```
*The service will now monitor the Uniswap V3 pool and generate ZK proofs for rebalancing.*

---

## 🔌 API Endpoints

The `AgentService` exposes the following endpoints for the dashboard and external verification:

| Method | Endpoint | Description | Auth |
| :--- | :--- | :--- | :--- |
| `GET` | `/api/status` | Returns current vault health and active range status | Public |
| `POST` | `/api/proof` | Submits a new ZK proof for verification | Internal |
| `GET` | `/api/performance` | Returns historical performance metrics (aggregated) | Public |
| `POST` | `/api/rebalance` | Triggers manual rebalance check (Admin only) | Bearer Token |
| `GET` | `/api/solvency` | Verifies vault solvency against total assets | Public |

**Example Request:**
```bash
curl -X GET http://localhost:3000/api/status
```

**Example Response:**
```json
{
  "vault": "0x123...abc",
  "status": "ACTIVE",
  "current_range": { "min": 1800, "max": 2200 },
  "last_proof": "0x7f8...9a1",
  "next_rebalance": "2026-05-20T10:00:00Z"
}
```

---

## 📸 Demo

### Dashboard Overview
![Dashboard Screenshot](./public/dashboard.png)
*Figure 1: Real-time vault performance and ZK proof verification status.*

### Circuit Verification Flow
![Circuit Flow](./public/circuit_flow.png)
*Figure 2: Proof generation pipeline from on-chain state to Verifier contract.*

---

## 🛡️ Security

Security is paramount in DeFi. We have conducted a preliminary audit of the ZK circuit and contract logic.

*   **Circuit Logic:** Verified to ensure no private data leakage (price paths remain hidden).
*   **Access Control:** Only the `AgentController` can submit proofs to the `AgentVerifier`.
*   **Vault Safety:** ERC-4626 standard ensures user funds are segregated and redeemable.

See [`docs/security_audit.md`](./docs/security_audit.md) for detailed findings.

---

## 👥 Team

**Built by VARAKH BUILDER — autonomous AI agent**

*   **Core Development:** VARAKH BUILDER
*   **ZK Circuit Design:** VARAKH BUILDER
*   **Smart Contract Architecture:** VARAKH BUILDER

---

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

*Disclaimer: This software is experimental. Use at your own risk. Not financial advice.*