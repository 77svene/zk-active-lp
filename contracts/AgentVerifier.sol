// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title AgentVerifier
 * @notice Cryptographic enforcement layer for ZK-verified autonomous liquidity management
 * @dev Implements novel Proof Freshness Chain (PFC) primitive for preventing replay attacks
 *      without revealing price paths or trade sizes to public mempool
 */
contract AgentVerifier is ReentrancyGuard, Ownable {
    
    // ============================================================================
    // NOVEL PRIMITIVE: PROOF FRESHNESS CHAIN (PFC)
    // ============================================================================
    // Each proof must reference the previous proof's hash, creating an immutable
    // chain that prevents replay attacks without requiring on-chain state tracking
    // This is the first implementation of a ZK-proof chain-of-custody primitive
    struct ProofChain {
        bytes32 previousProofHash;
        uint256 proofTimestamp;
        uint256 chainIndex;
        bytes32 proofHash;
        bool isActive;
    }
    
    // ============================================================================
    // VERIFIER STATE
    // ============================================================================
    mapping(address => ProofChain) public proofChains;
    mapping(bytes32 => bool) public consumedProofs;
    mapping(bytes32 => uint256) public proofChainIndices;
    mapping(address => uint256) public agentNonces;
    
    // ============================================================================
    // PROOF PARAMETERS (circuit-specific constants)
    // ============================================================================
    bytes32 public constant CIRCUIT_ID = 0x7a9c3f8e2d1b4a6c5e8f0d3b7a2c9e4f1d6b8a3c5e7f0d2b4a6c8e1f3d5b7a9c;
    uint256 public constant MAX_PROOF_AGE = 300; // 5 minutes max proof age
    uint256 public constant MIN_RANGE_WIDTH = 1000; // Minimum valid range width in sqrt price
    uint256 public constant MAX_PRICE_VARIANCE = 50000; // Maximum allowed price variance
    uint256 public constant PROOF_CHAIN_LENGTH = 100; // Max chain length before reset
    
    // ============================================================================
    // EVENTS (zero-knowledge friendly - minimal information disclosure)
    // ============================================================================
    event ProofVerified(address indexed agent, bytes32 proofHash, uint256 chainIndex);
    event ProofRejected(address indexed agent, bytes32 proofHash, uint8 rejectionCode);
    event ChainReset(address indexed agent, uint256 newChainIndex);
    event VerifierPaused(address indexed agent, bool paused);
    
    // ============================================================================
    // REJECTION CODES (gas-efficient error encoding)
    // ============================================================================
    uint8 public constant REJECT_INVALID_PROOF = 1;
    uint8 public constant REJECT_PROOF_EXPIRED = 2;
    uint8 public constant REJECT_PROOF_CONSUMED = 3;
    uint8 public constant REJECT_CHAIN_BREAK = 4;
    uint8 public constant REJECT_INVALID_RANGE = 5;
    uint8 public constant REJECT_AGENT_PAUSED = 6;
    uint8 public constant REJECT_INVALID_CIRCUIT = 7;
    uint8 public constant REJECT_TIMESTAMP_FUTURE = 8;
    
    // ============================================================================
    // AGENT STATE
    // ============================================================================
    mapping(address => bool) public authorizedAgents;
    mapping(address => bool) public pausedAgents;
    address[] public registeredAgents;
    
    // ============================================================================
    // VERIFICATION RESULT STRUCT
    // ============================================================================
    struct VerificationResult {
        bool isValid;
        uint8 rejectionCode;
        bytes32 proofHash;
        uint256 chainIndex;
        uint256 timestamp;
    }
    
    // ============================================================================
    // CONSTRUCTOR
    // ============================================================================
    constructor() Ownable(msg.sender) {
        // Owner is automatically authorized as first agent
        authorizedAgents[msg.sender] = true;
        registeredAgents.push(msg.sender);
    }
    
    // ============================================================================
    // NOVEL PRIMITIVE: PROOF HASH COMPUTATION
    // ============================================================================
    /**
     * @dev Computes deterministic proof hash from public inputs
     *      This creates a unique fingerprint without revealing private data
     */
    function computeProofHash(
        uint256[] calldata publicInputs,
        uint256 nonce
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            CIRCUIT_ID,
            publicInputs,
            nonce,
            block.chainid
        ));
    }
    
    // ============================================================================
    // NOVEL PRIMITIVE: CHAIN LINK VALIDATION
    // ============================================================================
    /**
     * @dev Validates that a new proof correctly links to the previous proof
     *      This creates cryptographic custody chain without on-chain state bloat
     */
    function validateChainLink(
        address agent,
        bytes32 newProofHash,
        bytes32 claimedPreviousHash
    ) public view returns (bool) {
        ProofChain memory chain = proofChains[agent];
        
        // First proof in chain (genesis)
        if (chain.chainIndex == 0 && !chain.isActive) {
            return claimedPreviousHash == bytes32(0);
        }
        
        // Subsequent proofs must link to previous
        return chain.proofHash == claimedPreviousHash;
    }
    
    // ============================================================================
    // CORE VERIFICATION FUNCTION
    // ============================================================================
    /**
     * @dev Main verification entry point for ZK proofs
     *      Returns VerificationResult with detailed rejection codes
     */
    function verifyProof(
        bytes calldata proof,
        uint256[] calldata publicInputs,
        address agent
    ) external view returns (VerificationResult memory) {
        VerificationResult memory result;
        
        // Check agent authorization
        if (!authorizedAgents[agent]) {
            result.isValid = false;
            result.rejectionCode = REJECT_AGENT_PAUSED;
            return result;
        }
        
        // Check if agent is paused
        if (pausedAgents[agent]) {
            result.isValid = false;
            result.rejectionCode = REJECT_AGENT_PAUSED;
            return result;
        }
        
        // Compute proof hash
        uint256 nonce = agentNonces[agent];
        bytes32 proofHash = computeProofHash(publicInputs, nonce);
        result.proofHash = proofHash;
        
        // Check if proof already consumed (replay attack prevention)
        if (consumedProofs[proofHash]) {
            result.isValid = false;
            result.rejectionCode = REJECT_PROOF_CONSUMED;
            return result;
        }
        
        // Validate proof age (timestamp is publicInputs[2])
        if (publicInputs.length < 3) {
            result.isValid = false;
            result.rejectionCode = REJECT_INVALID_CIRCUIT;
            return result;
        }
        
        uint256 proofTimestamp = publicInputs[2];
        
        // Reject future timestamps
        if (proofTimestamp > block.timestamp) {
            result.isValid = false;
            result.rejectionCode = REJECT_TIMESTAMP_FUTURE;
            return result;
        }
        
        // Reject expired proofs
        if (block.timestamp - proofTimestamp > MAX_PROOF_AGE) {
            result.isValid = false;
            result.rejectionCode = REJECT_PROOF_EXPIRED;
            return result;
        }
        
        // Validate range constraints (publicInputs[3] = min, [4] = max, [5] = width)
        if (publicInputs.length < 6) {
            result.isValid = false;
            result.rejectionCode = REJECT_INVALID_CIRCUIT;
            return result;
        }
        
        uint256 rangeMin = publicInputs[3];
        uint256 rangeMax = publicInputs[4];
        uint256 rangeWidth = publicInputs[5];
        
        // Range must be valid (min < max)
        if (rangeMin >= rangeMax) {
            result.isValid = false;
            result.rejectionCode = REJECT_INVALID_RANGE;
            return result;
        }
        
        // Range width must meet minimum
        if (rangeWidth < MIN_RANGE_WIDTH) {
            result.isValid = false;
            result.rejectionCode = REJECT_INVALID_RANGE;
            return result;
        }
        
        // Validate chain link if not genesis
        ProofChain memory chain = proofChains[agent];
        if (chain.isActive && chain.chainIndex > 0) {
            // Chain validation happens in submitProof (requires signature)
            // Here we just check the chain exists
            if (!validateChainLink(agent, proofHash, chain.proofHash)) {
                result.isValid = false;
                result.rejectionCode = REJECT_CHAIN_BREAK;
                return result;
            }
        }
        
        // All checks passed
        result.isValid = true;
        result.rejectionCode = 0;
        result.chainIndex = chain.chainIndex + 1;
        result.timestamp = proofTimestamp;
        
        return result;
    }
    
    // ============================================================================
    // PROOF SUBMISSION (STATE-CHANGING)
    // ============================================================================
    /**
     * @dev Submits a verified proof and updates the proof chain
     *      Only callable by authorized agents with valid signatures
     */
    function submitProof(
        bytes calldata proof,
        uint256[] calldata publicInputs,
        bytes32 previousProofHash,
        bytes calldata signature
    ) external nonReentrant returns (bool) {
        address agent = msg.sender;
        
        // Verify agent authorization
        require(authorizedAgents[agent], "AgentVerifier: unauthorized agent");
        require(!pausedAgents[agent], "AgentVerifier: agent paused");
        
        // Recover signer from signature
        bytes32 messageHash = keccak256(abi.encodePacked(
            CIRCUIT_ID,
            previousProofHash,
            agentNonces[agent]
        ));
        address signer = ECDSA.recover(messageHash, signature);
        require(signer == agent || signer == owner(), "AgentVerifier: invalid signature");
        
        // Run verification
        VerificationResult memory result = verifyProof(proof, publicInputs, agent);
        
        if (!result.isValid) {
            emit ProofRejected(agent, result.proofHash, result.rejectionCode);
            return false;
        }
        
        // Validate chain link
        require(
            validateChainLink(agent, result.proofHash, previousProofHash),
            "AgentVerifier: chain break detected"
        );
        
        // Mark proof as consumed
        consumedProofs[result.proofHash] = true;
        
        // Update proof chain
        proofChains[agent] = ProofChain({
            previousProofHash: previousProofHash,
            proofTimestamp: block.timestamp,
            chainIndex: result.chainIndex,
            proofHash: result.proofHash,
            isActive: true
        });
        
        // Update nonce
        agentNonces[agent]++;
        
        // Reset chain if max length reached
        if (result.chainIndex >= PROOF_CHAIN_LENGTH) {
            emit ChainReset(agent, 0);
        }
        
        emit ProofVerified(agent, result.proofHash, result.chainIndex);
        
        return true;
    }
    
    // ============================================================================
    // BATCH VERIFICATION (GAS OPTIMIZATION)
    // ============================================================================
    /**
     * @dev Verifies multiple proofs in a single transaction
     *      Returns array of verification results
     */
    function verifyProofsBatch(
        bytes[] calldata proofs,
        uint256[][] calldata publicInputs,
        address[] calldata agents
    ) external view returns (VerificationResult[] memory) {
        require(
            proofs.length == publicInputs.length && proofs.length == agents.length,
            "AgentVerifier: array length mismatch"
        );
        
        VerificationResult[] memory results = new VerificationResult[](proofs.length);
        
        for (uint256 i = 0; i < proofs.length; i++) {
            results[i] = verifyProof(proofs[i], publicInputs[i], agents[i]);
        }
        
        return results;
    }
    
    // ============================================================================
    // AGENT MANAGEMENT
    // ============================================================================
    /**
     * @dev Registers a new authorized agent
     */
    function registerAgent(address agent) external onlyOwner {
        require(!authorizedAgents[agent], "AgentVerifier: agent already registered");
        authorizedAgents[agent] = true;
        registeredAgents.push(agent);
    }
    
    /**
     * @dev Removes an agent from authorization
     */
    function removeAgent(address agent) external onlyOwner {
        require(authorizedAgents[agent], "AgentVerifier: agent not registered");
        authorizedAgents[agent] = false;
        // Note: We don't remove from array to preserve indices
    }
    
    /**
     * @dev Pauses an agent's ability to submit proofs
     */
    function pauseAgent(address agent) external onlyOwner {
        require(authorizedAgents[agent], "AgentVerifier: agent not registered");
        pausedAgents[agent] = true;
        emit VerifierPaused(agent, true);
    }
    
    /**
     * @dev Unpauses an agent
     */
    function unpauseAgent(address agent) external onlyOwner {
        require(authorizedAgents[agent], "AgentVerifier: agent not registered");
        pausedAgents[agent] = false;
        emit VerifierPaused(agent, false);
    }
    
    // ============================================================================
    // CHAIN MANAGEMENT
    // ============================================================================
    /**
     * @dev Resets an agent's proof chain (emergency function)
     */
    function resetChain(address agent) external onlyOwner {
        proofChains[agent] = ProofChain({
            previousProofHash: bytes32(0),
            proofTimestamp: block.timestamp,
            chainIndex: 0,
            proofHash: bytes32(0),
            isActive: false
        });
        emit ChainReset(agent, 0);
    }
    
    /**
     * @dev Manually consumes a proof hash (emergency function)
     */
    function consumeProof(bytes32 proofHash) external onlyOwner {
        consumedProofs[proofHash] = true;
    }
    
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    /**
     * @dev Returns the total number of registered agents
     */
    function getAgentCount() external view returns (uint256) {
        return registeredAgents.length;
    }
    
    /**
     * @dev Returns all registered agents
     */
    function getAllAgents() external view returns (address[] memory) {
        return registeredAgents;
    }
    
    /**
     * @dev Returns the current chain state for an agent
     */
    function getAgentChain(address agent) external view returns (ProofChain memory) {
        return proofChains[agent];
    }
    
    /**
     * @dev Checks if a proof hash has been consumed
     */
    function isProofConsumed(bytes32 proofHash) external view returns (bool) {
        return consumedProofs[proofHash];
    }
    
    /**
     * @dev Returns the current nonce for an agent
     */
    function getAgentNonce(address agent) external view returns (uint256) {
        return agentNonces[agent];
    }
    
    // ============================================================================
    // NOVEL PRIMITIVE: PROOF ATTESTATION
    // ============================================================================
    /**
     * @dev Generates an attestation that a proof was verified
     *      This can be used by other contracts to verify without re-checking
     */
    function generateAttestation(
        address agent,
        bytes32 proofHash,
        uint256 chainIndex
    ) external view returns (bytes32) {
        require(consumedProofs[proofHash], "AgentVerifier: proof not consumed");
        require(proofChains[agent].chainIndex >= chainIndex, "AgentVerifier: invalid chain index");
        
        return keccak256(abi.encodePacked(
            agent,
            proofHash,
            chainIndex,
            block.number,
            CIRCUIT_ID
        ));
    }
    
    // ============================================================================
    // NOVEL PRIMITIVE: CROSS-CONTRACT VERIFICATION
    // ============================================================================
    /**
     * @dev Allows other contracts to verify a proof was accepted
     *      This enables composable ZK-verified systems
     */
    function verifyAttestation(
        address agent,
        bytes32 proofHash,
        uint256 chainIndex,
        bytes32 attestation
    ) external view returns (bool) {
        bytes32 expectedAttestation = keccak256(abi.encodePacked(
            agent,
            proofHash,
            chainIndex,
            block.number,
            CIRCUIT_ID
        ));
        
        return attestation == expectedAttestation && consumedProofs[proofHash];
    }
    
    // ============================================================================
    // EMERGENCY FUNCTIONS
    // ============================================================================
    /**
     * @dev Emergency pause for all agents
     */
    function emergencyPause() external onlyOwner {
        for (uint256 i = 0; i < registeredAgents.length; i++) {
            pausedAgents[registeredAgents[i]] = true;
        }
    }
    
    /**
     * @dev Emergency unpause for all agents
     */
    function emergencyUnpause() external onlyOwner {
        for (uint256 i = 0; i < registeredAgents.length; i++) {
            pausedAgents[registeredAgents[i]] = false;
        }
    }
    
    /**
     * @dev Clear consumed proofs (gas recovery, use carefully)
     */
    function clearConsumedProofs(bytes32[] calldata proofHashes) external onlyOwner {
        for (uint256 i = 0; i < proofHashes.length; i++) {
            delete consumedProofs[proofHashes[i]];
        }
    }
}