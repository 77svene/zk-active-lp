// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IZKVerifier {
    function verifyProof(bytes calldata proof, uint256[] calldata publicInputs) external view returns (bool);
}

interface IUniswapV3Pool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked);
    function liquidity() external view returns (uint128);
    function tickSpacing() external view returns (int24);
    function position(uint256 tokenId) external view returns (
        uint96 nonce,
        address operator,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 tokensOwed0,
        uint256 tokensOwed1
    );
}

struct Position {
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 lastRebalanceTimestamp;
    uint256 zkProofHash;
}

struct Agent {
    address agentAddress;
    bool isActive;
    uint256 maxRebalanceInterval;
    uint256 lastRebalanceBlock;
    uint256 totalRebalances;
    bytes32 agentPublicKey;
}

contract AgentController is IERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    IERC20 public immutable shares;
    IZKVerifier public zkVerifier;
    IUniswapV3Pool public uniswapPool;
    
    mapping(address => uint256) public depositBalance;
    mapping(address => uint256) public withdrawBalance;
    mapping(uint256 => Position) public positions;
    mapping(address => Agent) public agents;
    uint256 public totalPositions;
    uint256 public totalAssets;
    uint256 public totalShares;
    uint256 public minRebalanceInterval;
    uint256 public maxRebalanceInterval;
    uint256 public feeBps;
    uint256 public feeCollector;
    
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event Rebalance(uint256 indexed positionId, uint256 timestamp, bytes32 zkProofHash);
    event AgentRegistered(address indexed agentAddress, bytes32 indexed publicKey);
    event AgentActivated(address indexed agentAddress);
    event AgentDeactivated(address indexed agentAddress);
    event FeeCollected(uint256 amount, address indexed to);

    constructor(
        IERC20 _asset,
        IERC20 _shares,
        IZKVerifier _zkVerifier,
        IUniswapV3Pool _uniswapPool,
        uint256 _minRebalanceInterval,
        uint256 _maxRebalanceInterval,
        uint256 _feeBps
    ) Ownable(msg.sender) {
        asset = _asset;
        shares = _shares;
        zkVerifier = _zkVerifier;
        uniswapPool = _uniswapPool;
        minRebalanceInterval = _minRebalanceInterval;
        maxRebalanceInterval = _maxRebalanceInterval;
        feeBps = _feeBps;
        feeCollector = msg.sender;
    }

    function totalAssets() public view override returns (uint256) {
        return totalAssets;
    }

    function totalSupply() public view override returns (uint256) {
        return totalShares;
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        if (totalAssets == 0) return assets;
        return (assets * totalShares) / totalAssets;
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        if (totalShares == 0) return shares;
        return (shares * totalAssets) / totalShares;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return depositBalance[owner];
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return withdrawBalance[owner];
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        require(assets > 0, "ZERO_ASSETS");
        shares = convertToShares(assets);
        require(shares > 0, "ZERO_SHARES");
        
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 afterBalance = asset.balanceOf(address(this));
        uint256 actualAssets = afterBalance - beforeBalance;
        
        totalAssets += actualAssets;
        totalShares += shares;
        depositBalance[receiver] += shares;
        
        emit Deposit(msg.sender, receiver, actualAssets, shares);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        require(shares > 0, "ZERO_SHARES");
        assets = convertToAssets(shares);
        require(assets > 0, "ZERO_ASSETS");
        
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 afterBalance = asset.balanceOf(address(this));
        uint256 actualAssets = afterBalance - beforeBalance;
        
        totalAssets += actualAssets;
        totalShares += shares;
        depositBalance[receiver] += shares;
        
        emit Deposit(msg.sender, receiver, actualAssets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        require(assets > 0, "ZERO_ASSETS");
        shares = convertToShares(assets);
        require(shares > 0, "ZERO_SHARES");
        require(depositBalance[owner] >= shares, "INSUFFICIENT_BALANCE");
        
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.safeTransfer(receiver, assets);
        uint256 afterBalance = asset.balanceOf(address(this));
        uint256 actualAssets = beforeBalance - afterBalance;
        
        totalAssets -= actualAssets;
        totalShares -= shares;
        depositBalance[owner] -= shares;
        
        emit Withdraw(msg.sender, receiver, owner, actualAssets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        require(shares > 0, "ZERO_SHARES");
        assets = convertToAssets(shares);
        require(assets > 0, "ZERO_ASSETS");
        require(depositBalance[owner] >= shares, "INSUFFICIENT_BALANCE");
        
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.safeTransfer(receiver, assets);
        uint256 afterBalance = asset.balanceOf(address(this));
        uint256 actualAssets = beforeBalance - afterBalance;
        
        totalAssets -= actualAssets;
        totalShares -= shares;
        depositBalance[owner] -= shares;
        
        emit Withdraw(msg.sender, receiver, owner, actualAssets, shares);
    }

    function registerAgent(address agentAddress, bytes32 publicKey, uint256 maxRebalanceInterval) public onlyOwner {
        require(!agents[agentAddress].isActive, "AGENT_EXISTS");
        agents[agentAddress] = Agent({
            agentAddress: agentAddress,
            isActive: false,
            maxRebalanceInterval: maxRebalanceInterval,
            lastRebalanceBlock: 0,
            totalRebalances: 0,
            agentPublicKey: publicKey
        });
        emit AgentRegistered(agentAddress, publicKey);
    }

    function activateAgent(address agentAddress) public onlyOwner {
        require(agents[agentAddress].agentAddress != address(0), "AGENT_NOT_REGISTERED");
        require(!agents[agentAddress].isActive, "AGENT_ALREADY_ACTIVE");
        agents[agentAddress].isActive = true;
        emit AgentActivated(agentAddress);
    }

    function deactivateAgent(address agentAddress) public onlyOwner {
        require(agents[agentAddress].agentAddress != address(0), "AGENT_NOT_REGISTERED");
        require(agents[agentAddress].isActive, "AGENT_NOT_ACTIVE");
        agents[agentAddress].isActive = false;
        emit AgentDeactivated(agentAddress);
    }

    function isAgentActive(address agentAddress) public view returns (bool) {
        return agents[agentAddress].isActive;
    }

    function createPosition(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bytes calldata zkProof,
        uint256[] calldata publicInputs
    ) public nonReentrant returns (uint256 positionId) {
        require(agents[msg.sender].isActive, "AGENT_NOT_ACTIVE");
        require(tickLower < tickUpper, "INVALID_RANGE");
        require(liquidity > 0, "ZERO_LIQUIDITY");
        
        require(
            zkVerifier.verifyProof(zkProof, publicInputs),
            "INVALID_ZK_PROOF"
        );
        
        uint256 currentBlock = block.number;
        require(
            currentBlock - agents[msg.sender].lastRebalanceBlock >= minRebalanceInterval,
            "REBALANCE_COOLDOWN"
        );
        
        positionId = totalPositions++;
        positions[positionId] = Position({
            tokenId: positionId,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            lastRebalanceTimestamp: block.timestamp,
            zkProofHash: keccak256(abi.encodePacked(zkProof, publicInputs))
        });
        
        agents[msg.sender].lastRebalanceBlock = currentBlock;
        agents[msg.sender].totalRebalances++;
        
        emit Rebalance(positionId, block.timestamp, keccak256(abi.encodePacked(zkProof, publicInputs)));
    }

    function rebalancePosition(
        uint256 positionId,
        int24 newTickLower,
        int24 newTickUpper,
        uint128 newLiquidity,
        bytes calldata zkProof,
        uint256[] calldata publicInputs
    ) public nonReentrant returns (bool success) {
        require(agents[msg.sender].isActive, "AGENT_NOT_ACTIVE");
        require(positionId < totalPositions, "INVALID_POSITION");
        
        Position storage position = positions[positionId];
        require(
            block.number - agents[msg.sender].lastRebalanceBlock >= minRebalanceInterval,
            "REBALANCE_COOLDOWN"
        );
        
        require(
            zkVerifier.verifyProof(zkProof, publicInputs),
            "INVALID_ZK_PROOF"
        );
        
        uint256 currentBlock = block.number;
        position.tickLower = newTickLower;
        position.tickUpper = newTickUpper;
        position.liquidity = newLiquidity;
        position.lastRebalanceTimestamp = block.timestamp;
        position.zkProofHash = keccak256(abi.encodePacked(zkProof, publicInputs));
        
        agents[msg.sender].lastRebalanceBlock = currentBlock;
        agents[msg.sender].totalRebalances++;
        
        emit Rebalance(positionId, block.timestamp, keccak256(abi.encodePacked(zkProof, publicInputs)));
        return true;
    }

    function getPoolCurrentPrice() public view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96, , , , , , ) = uniswapPool.slot0();
    }

    function getPositionInfo(uint256 positionId) public view returns (
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 lastRebalanceTimestamp,
        bytes32 zkProofHash
    ) {
        Position storage position = positions[positionId];
        return (
            position.tokenId,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.lastRebalanceTimestamp,
            position.zkProofHash
        );
    }

    function getAgentInfo(address agentAddress) public view returns (
        address agentAddress_,
        bool isActive,
        uint256 maxRebalanceInterval,
        uint256 lastRebalanceBlock,
        uint256 totalRebalances,
        bytes32 agentPublicKey
    ) {
        Agent storage agent = agents[agentAddress];
        return (
            agent.agentAddress,
            agent.isActive,
            agent.maxRebalanceInterval,
            agent.lastRebalanceBlock,
            agent.totalRebalances,
            agent.agentPublicKey
        );
    }

    function setFeeCollector(address newFeeCollector) public onlyOwner {
        feeCollector = newFeeCollector;
    }

    function setMinRebalanceInterval(uint256 newMinInterval) public onlyOwner {
        minRebalanceInterval = newMinInterval;
    }

    function setMaxRebalanceInterval(uint256 newMaxInterval) public onlyOwner {
        maxRebalanceInterval = newMaxInterval;
    }

    function setFeeBps(uint256 newFeeBps) public onlyOwner {
        require(newFeeBps <= 10000, "FEE_TOO_HIGH");
        feeBps = newFeeBps;
    }

    function collectFees(uint256 amount) public nonReentrant {
        require(msg.sender == feeCollector, "NOT_FEE_COLLECTOR");
        require(amount > 0, "ZERO_AMOUNT");
        require(amount <= asset.balanceOf(address(this)), "INSUFFICIENT_BALANCE");
        
        asset.safeTransfer(feeCollector, amount);
        emit FeeCollected(amount, feeCollector);
    }

    function emergencyWithdraw(uint256 amount) public onlyOwner {
        require(amount > 0, "ZERO_AMOUNT");
        require(amount <= asset.balanceOf(address(this)), "INSUFFICIENT_BALANCE");
        
        asset.safeTransfer(owner(), amount);
    }

    function getVaultStats() public view returns (
        uint256 totalAssets,
        uint256 totalShares,
        uint256 totalPositions,
        uint256 activeAgents,
        uint256 totalRebalances
    ) {
        totalAssets = this.totalAssets();
        totalShares = this.totalShares();
        totalPositions = this.totalPositions();
        
        for (uint256 i = 0; i < 1000; i++) {
            address testAgent = address(uint160(i));
            if (agents[testAgent].agentAddress != address(0)) {
                if (agents[testAgent].isActive) {
                    activeAgents++;
                }
                totalRebalances += agents[testAgent].totalRebalances;
            }
        }
    }
}