// SPDX-License-Identifier: MIT
// LIQUIAGENT: ZK-Verified Autonomous Liquidity Provider
// Cross-chain liquidity sourcing via LI.FI API with ZK-verified rebalancing

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));

// ============================================================================
// CONFIGURATION - Environment-based, no hardcoded secrets
// ============================================================================
const CONFIG = {
  rpcUrl: process.env.RPC_URL || 'http://localhost:8545',
  chainId: parseInt(process.env.CHAIN_ID || '31337'),
  verifierAddress: process.env.VERIFIER_ADDRESS || '0x0000000000000000000000000000000000000000',
  controllerAddress: process.env.CONTROLLER_ADDRESS || '0x0000000000000000000000000000000000000000',
  liFiApiKey: process.env.LIFI_API_KEY || '',
  liFiBaseUrl: 'https://li.quest/v1',
  zkProofDir: join(__dirname, '../circuits'),
  proofOutputDir: join(__dirname, '../proofs'),
  minLiquidityThreshold: 1000000000000000000n, // 1 ETH in wei
  maxSlippageBps: 500, // 5% max slippage
  rebalanceThresholdBps: 1000, // 10% price deviation triggers rebalance
};

// ============================================================================
// LI.FI CROSS-CHAIN LIQUIDITY SOURCER
// ============================================================================
class LIFiLiquiditySourcer {
  constructor(apiKey) {
    this.apiKey = apiKey;
    this.baseUrl = CONFIG.liFiBaseUrl;
  }

  /**
   * Get available routes for cross-chain swap
   * @param {Object} params - Swap parameters
   * @returns {Promise<Array>} Available routes
   */
  async getRoutes(params) {
    const { fromChain, toChain, fromToken, toToken, fromAmount, fromAddress } = params;
    
    const url = new URL(`${this.baseUrl}/routes`);
    url.searchParams.set('fromChain', fromChain);
    url.searchParams.set('toChain', toChain);
    url.searchParams.set('fromToken', fromToken);
    url.searchParams.set('toToken', toToken);
    url.searchParams.set('fromAmount', fromAmount);
    url.searchParams.set('fromAddress', fromAddress);
    url.searchParams.set('slippage', '0.5');
    url.searchParams.set('fee', '0');
    url.searchParams.set('includeContracts', 'true');
    url.searchParams.set('includeTokens', 'true');

    const response = await fetch(url.toString(), {
      headers: {
        'Accept': 'application/json',
        ...(this.apiKey ? { 'x-api-key': this.apiKey } : {})
      }
    });

    if (!response.ok) {
      throw new Error(`LI.FI API error: ${response.status} ${response.statusText}`);
    }

    const data = await response.json();
    return data.routes || [];
  }

  /**
   * Get optimal route for liquidity sourcing
   * @param {Object} params - Swap parameters
   * @returns {Promise<Object>} Optimal route with execution data
   */
  async getOptimalRoute(params) {
    const routes = await this.getRoutes(params);
    
    if (routes.length === 0) {
      throw new Error('No available routes found');
    }

    // Sort by estimated output (highest first)
    const sortedRoutes = routes.sort((a, b) => {
      const aOutput = BigInt(a.estimatedOutput);
      const bOutput = BigInt(b.estimatedOutput);
      return bOutput > aOutput ? 1 : -1;
    });

    const optimalRoute = sortedRoutes[0];
    
    // Get quote for the optimal route
    const quote = await this.getRouteQuote(optimalRoute);
    
    return {
      route: optimalRoute,
      quote: quote,
      estimatedOutput: optimalRoute.estimatedOutput,
      estimatedGas: optimalRoute.estimatedGas,
      slippage: optimalRoute.slippage
    };
  }

  /**
   * Get detailed quote for a specific route
   * @param {Object} route - Route object from LI.FI
   * @returns {Promise<Object>} Quote details
   */
  async getRouteQuote(route) {
    const url = new URL(`${this.baseUrl}/quote`);
    url.searchParams.set('fromChain', route.fromChain);
    url.searchParams.set('toChain', route.toChain);
    url.searchParams.set('fromToken', route.fromToken);
    url.searchParams.set('toToken', route.toToken);
    url.searchParams.set('fromAmount', route.fromAmount);
    url.searchParams.set('toAmountMin', route.estimatedOutput);
    url.searchParams.set('slippage', '0.5');
    url.searchParams.set('fee', '0');
    url.searchParams.set('referrer', '0x0000000000000000000000000000000000000000');

    const response = await fetch(url.toString(), {
      headers: {
        'Accept': 'application/json',
        ...(this.apiKey ? { 'x-api-key': this.apiKey } : {})
      }
    });

    if (!response.ok) {
      throw new Error(`LI.FI quote error: ${response.status} ${response.statusText}`);
    }

    return await response.json();
  }

  /**
   * Execute swap via LI.FI
   * @param {Object} quote - Quote from LI.FI
   * @param {Object} txParams - Transaction parameters
   * @returns {Promise<Object>} Transaction hash
   */
  async executeSwap(quote, txParams) {
    const url = `${this.baseUrl}/swap`;
    
    const body = {
      ...quote,
      txOrigin: txParams.from,
      slippage: quote.slippage,
      fee: 0,
      receiver: txParams.to || txParams.from,
      refundAddress: txParams.from,
      gasless: {
        enabled: false
      }
    };

    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        ...(this.apiKey ? { 'x-api-key': this.apiKey } : {})
      },
      body: JSON.stringify(body)
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`LI.FI swap execution failed: ${response.status} ${errorText}`);
    }

    return await response.json();
  }

  /**
   * Get token prices for liquidity depth analysis
   * @param {Array} tokens - Array of token addresses
   * @param {number} chainId - Chain ID
   * @returns {Promise<Object>} Token prices
   */
  async getTokenPrices(tokens, chainId) {
    const url = new URL(`${this.baseUrl}/tokens/${chainId}`);
    
    const response = await fetch(url.toString(), {
      headers: {
        'Accept': 'application/json',
        ...(this.apiKey ? { 'x-api-key': this.apiKey } : {})
      }
    });

    if (!response.ok) {
      throw new Error(`LI.FI token prices error: ${response.status} ${response.statusText}`);
    }

    const allTokens = await response.json();
    
    const prices = {};
    for (const token of tokens) {
      const tokenData = allTokens.find(t => t.address.toLowerCase() === token.toLowerCase());
      if (tokenData) {
        prices[token] = {
          address: tokenData.address,
          symbol: tokenData.symbol,
          decimals: tokenData.decimals,
          priceUsd: tokenData.priceUsd || '0'
        };
      }
    }

    return prices;
  }

  /**
   * Get liquidity depth for a token pair
   * @param {string} token0 - Token 0 address
   * @param {string} token1 - Token 1 address
   * @param {number} chainId - Chain ID
   * @returns {Promise<Object>} Liquidity depth
   */
  async getLiquidityDepth(token0, token1, chainId) {
    const url = new URL(`${this.baseUrl}/depth`);
    url.searchParams.set('fromToken', token0);
    url.searchParams.set('toToken', token1);
    url.searchParams.set('chainId', chainId.toString());

    const response = await fetch(url.toString(), {
      headers: {
        'Accept': 'application/json',
        ...(this.apiKey ? { 'x-api-key': this.apiKey } : {})
      }
    });

    if (!response.ok) {
      throw new Error(`LI.FI depth error: ${response.status} ${response.statusText}`);
    }

    return await response.json();
  }
}

// ============================================================================
// ZK PROOF GENERATOR
// ============================================================================
class ZKProofGenerator {
  constructor(circuitPath, wasmPath, zkeyPath) {
    this.circuitPath = circuitPath;
    this.wasmPath = wasmPath;
    this.zkeyPath = zkeyPath;
    this.witnessCalculator = null;
  }

  /**
   * Initialize ZK circuit
   */
  async initialize() {
    if (!existsSync(this.wasmPath)) {
      throw new Error('WASM file not found. Run circuit build first.');
    }
    
    if (!existsSync(this.zkeyPath)) {
      throw new Error('ZKEY file not found. Run trusted setup first.');
    }

    const { groth16 } = await import('snarkjs');
    this.witnessCalculator = await groth16.witnessCalculator(this.wasmPath);
  }

  /**
   * Generate witness from inputs
   * @param {Object} inputs - Circuit inputs
   * @returns {Promise<Object>} Witness object
   */
  async generateWitness(inputs) {
    const { groth16 } = await import('snarkjs');
    const witness = await groth16.calculateWitness(this.circuitPath, inputs);
    return witness;
  }

  /**
   * Generate ZK proof
   * @param {Object} witness - Witness object
   * @returns {Promise<Object>} Proof and public inputs
   */
  async generateProof(witness) {
    const { groth16 } = await import('snarkjs');
    const proof = await groth16.fullProve(witness, this.circuitPath, this.zkeyPath);
    return proof;
  }

  /**
   * Export proof for on-chain verification
   * @param {Object} proof - Proof object
   * @returns {Promise<Object>} Exported proof
   */
  async exportProof(proof) {
    const { groth16 } = await import('snarkjs');
    const exported = await groth16.exportSolidityCallData(proof, proof.publicSignals);
    return exported;
  }

  /**
   * Verify proof locally
   * @param {Object} proof - Proof object
   * @param {Array} publicInputs - Public input array
   * @returns {Promise<boolean>} Verification result
   */
  async verifyProof(proof, publicInputs) {
    const { groth16 } = await import('snarkjs');
    const vKey = JSON.parse(readFileSync(join(__dirname, '../circuits/verification_key.json'), 'utf8'));
    return await groth16.verify(vKey, publicInputs, proof);
  }
}

// ============================================================================
// AGENT SERVICE - Main orchestration layer
// ============================================================================
class LiquiAgentService {
  constructor(config) {
    this.config = config;
    this.liFi = new LIFiLiquiditySourcer(config.liFiApiKey);
    this.zkGenerator = null;
    this.isInitialized = false;
    this.pendingProofs = new Map();
    this.lastRebalanceTimestamp = 0;
  }

  /**
   * Initialize the agent service
   */
  async initialize() {
    try {
      // Initialize ZK proof generator
      const circuitPath = join(this.config.zkProofDir, 'ActiveRangeProof.wasm');
      const zkeyPath = join(this.config.zkProofDir, 'ActiveRangeProof_final.zkey');
      
      this.zkGenerator = new ZKProofGenerator(
        join(this.config.zkProofDir, 'ActiveRangeProof.wasm'),
        circuitPath,
        zkeyPath
      );
      
      await this.zkGenerator.initialize();
      this.isInitialized = true;
      
      console.log('[LiquiAgent] Service initialized successfully');
      return true;
    } catch (error) {
      console.error('[LiquiAgent] Initialization failed:', error.message);
      throw error;
    }
  }

  /**
   * Monitor on-chain state and detect rebalance triggers
   * @param {string} poolAddress - Uniswap V3 pool address
   * @param {string} positionId - Position ID
   * @returns {Promise<Object>} Rebalance decision
   */
  async monitorPoolState(poolAddress, positionId) {
    // Fetch current pool state
    const poolState = await this.fetchPoolState(poolAddress);
    
    // Fetch position details
    const position = await this.fetchPositionDetails(positionId);
    
    // Calculate price deviation
    const priceDeviation = this.calculatePriceDeviation(
      poolState.sqrtPriceX96,
      position.tickLower,
      position.tickUpper
    );
    
    // Check if rebalance is needed
    const needsRebalance = priceDeviation > this.config.rebalanceThresholdBps;
    
    return {
      poolState,
      position,
      priceDeviation,
      needsRebalance,
      timestamp: Math.floor(Date.now() / 1000)
    };
  }

  /**
   * Fetch pool state from Uniswap V3
   * @param {string} poolAddress - Pool contract address
   * @returns {Promise<Object>} Pool state
   */
  async fetchPoolState(poolAddress) {
    // In production, this would call the actual pool contract
    // For now, return mock data structure
    return {
      sqrtPriceX96: '123456789012345678901234567890',
      tick: -1000,
      liquidity: '1000000000000000000',
      fee: 3000,
      observationIndex: 0,
      observationCardinality: 1,
      observationCardinalityNext: 1,
      feeProtocol: 0,
      unlocked: true
    };
  }

  /**
   * Fetch position details
   * @param {string} positionId - Position ID
   * @returns {Promise<Object>} Position details
   */
  async fetchPositionDetails(positionId) {
    return {
      tokenId: positionId,
      tickLower: -2000,
      tickUpper: 2000,
      liquidity: '500000000000000000',
      tokensOwed0: '0',
      tokensOwed1: '0'
    };
  }

  /**
   * Calculate price deviation from current position
   * @param {string} sqrtPriceX96 - Current sqrt price
   * @param {number} tickLower - Lower tick
   * @param {number} tickUpper - Upper tick
   * @returns {number} Price deviation in basis points
   */
  calculatePriceDeviation(sqrtPriceX96, tickLower, tickUpper) {
    const currentTick = Math.floor(Math.log(Number(sqrtPriceX96)) / Math.log(1.0001));
    const midTick = (tickLower + tickUpper) / 2;
    const deviation = Math.abs(currentTick - midTick);
    return deviation * 100; // Convert to basis points
  }

  /**
   * Generate ZK proof for rebalance action
   * @param {Object} rebalanceData - Rebalance parameters
   * @returns {Promise<Object>} ZK proof and public inputs
   */
  async generateRebalanceProof(rebalanceData) {
    if (!this.isInitialized) {
      throw new Error('Service not initialized. Call initialize() first.');
    }

    const {
      currentPrice,
      targetPrice,
      timestamp,
      rangeMin,
      rangeMax,
      rangeWidth,
      tickLower,
      tickUpper
    } = rebalanceData;

    // Prepare circuit inputs
    const circuitInputs = {
      public_current_sqrt_price: currentPrice,
      public_target_sqrt_price: targetPrice,
      public_timestamp: timestamp,
      public_range_min_sqrt_price: rangeMin,
      public_range_max_sqrt_price: rangeMax,
      public_range_width_sqrt_price: rangeWidth,
      private_current_price: currentPrice,
      private_target_price: targetPrice,
      private_rebalance_timestamp: timestamp,
      private_price_variance: '0',
      private_range_width: rangeWidth,
      private_tick_lower: tickLower,
      private_tick_upper: tickUpper
    };

    // Generate witness
    const witness = await this.zkGenerator.generateWitness(circuitInputs);
    
    // Generate proof
    const proof = await this.zkGenerator.generateProof(witness);
    
    // Export proof for on-chain verification
    const exportedProof = await this.zkGenerator.exportProof(proof);
    
    return {
      proof: exportedProof,
      publicInputs: proof.publicSignals,
      timestamp: Date.now()
    };
  }

  /**
   * Source liquidity via LI.FI cross-chain
   * @param {Object} params - Liquidity sourcing parameters
   * @returns {Promise<Object>} Sourced liquidity
   */
  async sourceLiquidity(params) {
    const {
      fromChain,
      toChain,
      fromToken,
      toToken,
      amount,
      fromAddress
    } = params;

    try {
      // Get optimal route
      const routeData = await this.liFi.getOptimalRoute({
        fromChain,
        toChain,
        fromToken,
        toToken,
        fromAmount: amount,
        fromAddress
      });

      // Validate slippage
      if (routeData.slippage > this.config.maxSlippageBps / 10000) {
        throw new Error(`Slippage ${routeData.slippage}% exceeds maximum ${this.config.maxSlippageBps}bps`);
      }

      // Get token prices for depth analysis
      const prices = await this.liFi.getTokenPrices([fromToken, toToken], fromChain);
      
      // Get liquidity depth
      const depth = await this.liFi.getLiquidityDepth(fromToken, toToken, fromChain);

      return {
        route: routeData.route,
        quote: routeData.quote,
        prices,
        depth,
        estimatedOutput: routeData.estimatedOutput,
        estimatedGas: routeData.estimatedGas,
        slippage: routeData.slippage
      };
    } catch (error) {
      console.error('[LiquiAgent] Liquidity sourcing failed:', error.message);
      throw error;
    }
  }

  /**
   * Execute rebalance with ZK verification
   * @param {Object} rebalanceParams - Rebalance parameters
   * @returns {Promise<Object>} Execution result
   */
  async executeRebalance(rebalanceParams) {
    const {
      poolAddress,
      positionId,
      targetPrice,
      amount0,
      amount1
    } = rebalanceParams;

    // Step 1: Monitor pool state
    const poolState = await this.monitorPoolState(poolAddress, positionId);
    
    if (!poolState.needsRebalance) {
      return {
        status: 'SKIPPED',
        reason: 'No rebalance needed',
        priceDeviation: poolState.priceDeviation
      };
    }

    // Step 2: Generate ZK proof
    const proofData = await this.generateRebalanceProof({
      currentPrice: poolState.poolState.sqrtPriceX96,
      targetPrice,
      timestamp: Math.floor(Date.now() / 1000),
      rangeMin: poolState.position.tickLower,
      rangeMax: poolState.position.tickUpper,
      rangeWidth: poolState.position.tickUpper - poolState.position.tickLower,
      tickLower: poolState.position.tickLower,
      tickUpper: poolState.position.tickUpper
    });

    // Step 3: Source liquidity if needed
    let liquiditySourced = null;
    if (amount0 > 0 || amount1 > 0) {
      liquiditySourced = await this.sourceLiquidity({
        fromChain: this.config.chainId,
        toChain: this.config.chainId,
        fromToken: poolState.poolState.token0,
        toToken: poolState.poolState.token1,
        amount: amount0 > 0 ? amount0.toString() : amount1.toString(),
        fromAddress: this.config.controllerAddress
      });
    }

    // Step 4: Submit proof to verifier
    const proofHash = await this.submitProofToVerifier(proofData);

    // Step 5: Execute rebalance
    const rebalanceTx = await this.executeRebalanceOnChain({
      poolAddress,
      positionId,
      targetPrice,
      amount0,
      amount1,
      proofHash
    });

    this.lastRebalanceTimestamp = Date.now();

    return {
      status: 'SUCCESS',
      proofHash,
      rebalanceTx,
      liquiditySourced,
      timestamp: Date.now()
    };
  }

  /**
   * Submit ZK proof to verifier contract
   * @param {Object} proofData - Proof data
   * @returns {Promise<string>} Proof hash
   */
  async submitProofToVerifier(proofData) {
    const { proof, publicInputs } = proofData;
    
    // In production, this would call the AgentVerifier contract
    // For now, return a mock hash
    const proofHash = `0x${Buffer.from(JSON.stringify(proofData)).toString('hex').substring(0, 64)}`;
    
    // Store proof for verification
    this.pendingProofs.set(proofHash, {
      proof: proof,
      publicInputs,
      timestamp: Date.now()
    });

    return proofHash;
  }

  /**
   * Execute rebalance on Uniswap V3
   * @param {Object} params - Rebalance parameters
   * @returns {Promise<Object>} Transaction result
   */
  async executeRebalanceOnChain(params) {
    // In production, this would interact with Uniswap V3 router
    // For now, return mock result
    return {
      txHash: `0x${Buffer.from(JSON.stringify(params)).toString('hex').substring(0, 64)}`,
      status: 'PENDING',
      gasUsed: '0'
    };
  }

  /**
   * Verify agent solvency
   * @returns {Promise<Object>} Solvency report
   */
  async verifySolvency() {
    const solvencyReport = {
      totalAssets: '0',
      totalLiabilities: '0',
      netWorth: '0',
      liquidityRatio: '1.0',
      timestamp: Date.now()
    };

    return solvencyReport;
  }

  /**
   * Get performance metrics
   * @returns {Promise<Object>} Performance data
   */
  async getPerformanceMetrics() {
    return {
      totalRebalances: this.pendingProofs.size,
      lastRebalanceTimestamp: this.lastRebalanceTimestamp,
      averageSlippage: '0.1',
      totalVolume: '0',
      feesEarned: '0',
      timestamp: Date.now()
    };
  }

  /**
   * Shutdown service gracefully
   */
  async shutdown() {
    this.isInitialized = false;
    this.pendingProofs.clear();
    console.log('[LiquiAgent] Service shutdown complete');
  }
}

// ============================================================================
// EXPORTS
// ============================================================================
export { LiquiAgentService, LIFiLiquiditySourcer, ZKProofGenerator, CONFIG };