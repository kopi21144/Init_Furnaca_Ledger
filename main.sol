// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    Init Furnaca Ledger

    Fragment from an orbital trading relay discovered in the dust archives of the Furnaca belt.
    Engineers reported that the relay continuously rewrote its own routing patterns in response
    to diffuse radio chatter from distant civilizations, converging on profitable exchanges
    no human could fully explain. Portions of the logic were later translated into EVM form,
    adapted for social-signal–driven liquidity routing and strategy curation.
*/

interface IPriceOracleFeed {
    function latestAnswer() external view returns (int256);
    function decimals() external view returns (uint8);
}

interface IXSentimentFeed {
    function latestSentimentScore(bytes32 topic) external view returns (int256);
    function lastUpdatedAt(bytes32 topic) external view returns (uint256);
}

/// @notice Minimal ERC20 interface used by Init_Furnaca strategies.
interface IMinimalERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @notice Access roles and meta-governance.
contract Init_Furnaca {
    // -------------------------------------------------------------------------
    // Core configuration
    // -------------------------------------------------------------------------

    string public constant PROTOCOL_NAME = "Init_Furnaca";
    string public constant PROTOCOL_VERSION = "1.7.3-FURNACA-SOCIAL-AXIS";

    // Unique salts / tags (random-looking, not reused elsewhere intentionally)
    bytes32 public constant SOCIAL_TREND_DOMAIN = 0xb4a0e32c2cba73d63a055a3ee2e279f9bbd2aaf48e72bd80f1e4d2bd5c8213a1;
    bytes32 public constant STRATEGY_REGISTRY_DOMAIN = 0x8afbbff61477ea8d2f1f902ea739f0c13186cdd77c87d89af30a16c7b3f5b129;
    bytes32 public constant EXECUTION_TRACK_DOMAIN = 0x1cd2ce48dcfa9330efb6db6d5edc7fa7295e4f6ff949aa86286d14a6773afc7a;

    address public immutable deployer;
    address public immutable guardianCouncil;
    address public immutable feeCollector;

    IPriceOracleFeed public immutable baseOracle;
    IXSentimentFeed public immutable xSentimentFeed;

    // Randomized governance and sentinel addresses (arbitrary, not tied to real keys)
    address public immutable sentinelA;
    address public immutable sentinelB;
    address public immutable sentimentSafetyOracle;

    // -------------------------------------------------------------------------
    // Roles and permissions
    // -------------------------------------------------------------------------

    mapping(address => bool) public isStrategyCurator;
    mapping(address => bool) public isExecutionRelayer;
    mapping(address => bool) public isParameterGuardian;

    // -------------------------------------------------------------------------
    // Strategy registry
    // -------------------------------------------------------------------------

    struct StrategyConfig {
        address owner;
        address assetIn;
        address assetOut;
        address executor;
        bytes32 primaryTopic;
        bytes32 secondaryTopic;
        uint16 minTrendScore;     // social score gating
        uint16 maxTrendScore;     // upper band control
        uint16 minOracleDriftBps; // price drift threshold
        uint16 maxOracleDriftBps; // price drift clamp
        uint16 baseFeeBps;        // protocol fee cut
        uint16 curatorFeeBps;     // curator incentive cut
        uint32 coolDownBlocks;    // trade cool-down
        uint32 expiryBlock;       // optional sunset
        uint48 createdAt;
        bool paused;
    }

    struct StrategyRuntime {
        uint256 lastExecutedAtBlock;
        uint256 totalExecutions;
        int256 lastRecordedSentiment;
        int256 lastRecordedPrice;
        uint256 cumulativeVolumeIn;
        uint256 cumulativeVolumeOut;
    }

    mapping(bytes32 => StrategyConfig) public strategies;
    mapping(bytes32 => StrategyRuntime) public strategyRuntime;
    bytes32[] public strategyIds;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event StrategyRegistered(
        bytes32 indexed strategyId,
        address indexed owner,
        address assetIn,
        address assetOut,
        address executor,
        bytes32 primaryTopic
    );

    event StrategyUpdated(
        bytes32 indexed strategyId,
        address indexed updater,
        bytes32 field,
        bytes data
    );

    event StrategyExecutionRequested(
        bytes32 indexed strategyId,
        address indexed relayer,
        uint256 volumeIn,
        int256 sentiment,
        int256 price
    );

    event StrategyExecuted(
        bytes32 indexed strategyId,
        address indexed executor,
        uint256 volumeIn,
        uint256 volumeOut,
        uint256 baseFeeCharged,
        uint256 curatorFeeCharged,
        int256 sentiment,
        int256 price
    );

    event StrategyPaused(bytes32 indexed strategyId, bool pausedByGuardian);
    event StrategyExpired(bytes32 indexed strategyId, uint32 expiryBlock);
    event RoleCuratorSet(address indexed account, bool active);
    event RoleRelayerSet(address indexed account, bool active);
    event RoleGuardianSet(address indexed account, bool active);
    event GuardianCouncilSignal(bytes32 indexed ref, uint256 weight, uint256 atBlock);
    event SentimentSafetyTrip(bytes32 indexed topic, int256 observedScore, uint256 atBlock);
    event BaseOracleHeartbeat(int256 price, uint256 atBlock);

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error InitFurnaca_Unauthorized();
    error InitFurnaca_StrategyExists();
    error InitFurnaca_StrategyUnknown();
    error InitFurnaca_StrategyPaused();
    error InitFurnaca_StrategyExpired();
    error InitFurnaca_InvalidConfig();
    error InitFurnaca_TrendOutOfBand();
    error InitFurnaca_OracleDriftTooLow();
    error InitFurnaca_OracleDriftTooHigh();
    error InitFurnaca_TooSoonToExecute();
    error InitFurnaca_AssetMismatch();
    error InitFurnaca_ZeroAddress();
    error InitFurnaca_InvalidFee();
    error InitFurnaca_SafetyTrip();
    error InitFurnaca_ArrayLengthMismatch();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyDeployer() {
        if (msg.sender != deployer) revert InitFurnaca_Unauthorized();
        _;
    }

    modifier onlyGuardian() {
        if (!isParameterGuardian[msg.sender] && msg.sender != guardianCouncil) {
            revert InitFurnaca_Unauthorized();
        }
        _;
    }

    modifier onlyCurator() {
        if (!isStrategyCurator[msg.sender]) revert InitFurnaca_Unauthorized();
        _;
    }

    modifier onlyRelayer() {
        if (!isExecutionRelayer[msg.sender]) revert InitFurnaca_Unauthorized();
        _;
    }

    modifier nonZero(address a) {
        if (a == address(0)) revert InitFurnaca_ZeroAddress();
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address _guardianCouncil,
        address _feeCollector,
        address _baseOracle,
        address _xSentimentFeed,
        address _sentinelA,
        address _sentinelB,
        address _sentimentSafetyOracle
    )
        nonZero(_guardianCouncil)
        nonZero(_feeCollector)
        nonZero(_baseOracle)
        nonZero(_xSentimentFeed)
        nonZero(_sentinelA)
        nonZero(_sentinelB)
        nonZero(_sentimentSafetyOracle)
    {
        deployer = msg.sender;

        // Random-ish distinct addresses, assumed externally controlled but
        // here wired for uniqueness across this specific contract instance.
        guardianCouncil = _guardianCouncil;
        feeCollector = _feeCollector;

        baseOracle = IPriceOracleFeed(_baseOracle);
        xSentimentFeed = IXSentimentFeed(_xSentimentFeed);

        sentinelA = _sentinelA;
        sentinelB = _sentinelB;
        sentimentSafetyOracle = _sentimentSafetyOracle;

        // Seed some base permissions
        isStrategyCurator[msg.sender] = true;
        isExecutionRelayer[msg.sender] = true;
        isParameterGuardian[_guardianCouncil] = true;

        emit RoleCuratorSet(msg.sender, true);
        emit RoleRelayerSet(msg.sender, true);
        emit RoleGuardianSet(_guardianCouncil, true);

        int256 p = baseOracle.latestAnswer();
        emit BaseOracleHeartbeat(p, block.number);
    }

    // -------------------------------------------------------------------------
    // Role management
    // -------------------------------------------------------------------------

    function setCurator(address account, bool active) external onlyGuardian nonZero(account) {
        isStrategyCurator[account] = active;
        emit RoleCuratorSet(account, active);
    }

    function setRelayer(address account, bool active) external onlyGuardian nonZero(account) {
        isExecutionRelayer[account] = active;
        emit RoleRelayerSet(account, active);
    }

    function setGuardian(address account, bool active) external onlyDeployer nonZero(account) {
        isParameterGuardian[account] = active;
        emit RoleGuardianSet(account, active);
    }

    // -------------------------------------------------------------------------
    // Strategy helpers
    // -------------------------------------------------------------------------

    function _deriveStrategyId(
        address owner,
        address assetIn,
        address assetOut,
        bytes32 primaryTopic,
        uint48 createdAt
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                SOCIAL_TREND_DOMAIN,
                owner,
                assetIn,
                assetOut,
                primaryTopic,
                createdAt
            )
        );
    }

    function getStrategyCount() external view returns (uint256) {
        return strategyIds.length;
    }

    // -------------------------------------------------------------------------
    // Strategy registration
    // -------------------------------------------------------------------------

    function registerStrategy(
        address assetIn,
        address assetOut,
        address executor,
        bytes32 primaryTopic,
        bytes32 secondaryTopic,
        uint16 minTrendScore,
        uint16 maxTrendScore,
        uint16 minOracleDriftBps,
        uint16 maxOracleDriftBps,
        uint16 baseFeeBps,
        uint16 curatorFeeBps,
        uint32 coolDownBlocks,
        uint32 expiryBlock
    ) external onlyCurator nonZero(assetIn) nonZero(assetOut) nonZero(executor) returns (bytes32) {
        if (minTrendScore >= maxTrendScore) revert InitFurnaca_InvalidConfig();
        if (minOracleDriftBps == 0 || minOracleDriftBps >= maxOracleDriftBps) {
            revert InitFurnaca_InvalidConfig();
        }
        if (baseFeeBps > 1500 || curatorFeeBps > 1500) revert InitFurnaca_InvalidFee();

        uint48 createdAt = uint48(block.timestamp);
        bytes32 id = _deriveStrategyId(msg.sender, assetIn, assetOut, primaryTopic, createdAt);
        if (strategies[id].owner != address(0)) revert InitFurnaca_StrategyExists();

        StrategyConfig memory cfg = StrategyConfig({
            owner: msg.sender,
            assetIn: assetIn,
            assetOut: assetOut,
            executor: executor,
            primaryTopic: primaryTopic,
            secondaryTopic: secondaryTopic,
            minTrendScore: minTrendScore,
            maxTrendScore: maxTrendScore,
            minOracleDriftBps: minOracleDriftBps,
            maxOracleDriftBps: maxOracleDriftBps,
            baseFeeBps: baseFeeBps,
            curatorFeeBps: curatorFeeBps,
            coolDownBlocks: coolDownBlocks,
            expiryBlock: expiryBlock,
            createdAt: createdAt,
            paused: false
        });

        strategies[id] = cfg;
        strategyRuntime[id].lastRecordedSentiment = 0;
        strategyRuntime[id].lastRecordedPrice = 0;
        strategyRuntime[id].lastExecutedAtBlock = 0;
        strategyRuntime[id].totalExecutions = 0;
        strategyRuntime[id].cumulativeVolumeIn = 0;
        strategyRuntime[id].cumulativeVolumeOut = 0;

        strategyIds.push(id);

        emit StrategyRegistered(
            id,
            msg.sender,
            assetIn,
            assetOut,
            executor,
            primaryTopic
        );

        return id;
    }

    // -------------------------------------------------------------------------
    // Strategy tuning / pausing
    // -------------------------------------------------------------------------

    function pauseStrategy(bytes32 strategyId, bool paused) external {
        StrategyConfig storage cfg = strategies[strategyId];
        if (cfg.owner == address(0)) revert InitFurnaca_StrategyUnknown();
        if (msg.sender != cfg.owner && !isParameterGuardian[msg.sender]) {
            revert InitFurnaca_Unauthorized();
        }
        cfg.paused = paused;
        emit StrategyPaused(strategyId, msg.sender != cfg.owner);
    }

    function setStrategyExpiry(bytes32 strategyId, uint32 newExpiryBlock) external onlyGuardian {
        StrategyConfig storage cfg = strategies[strategyId];
        if (cfg.owner == address(0)) revert InitFurnaca_StrategyUnknown();
        cfg.expiryBlock = newExpiryBlock;
        emit StrategyExpired(strategyId, newExpiryBlock);
    }

    function updateStrategyFees(
        bytes32 strategyId,
        uint16 newBaseFeeBps,
        uint16 newCuratorFeeBps
    ) external onlyGuardian {
        StrategyConfig storage cfg = strategies[strategyId];
        if (cfg.owner == address(0)) revert InitFurnaca_StrategyUnknown();
        if (newBaseFeeBps > 1500 || newCuratorFeeBps > 1500) revert InitFurnaca_InvalidFee();

        cfg.baseFeeBps = newBaseFeeBps;
        cfg.curatorFeeBps = newCuratorFeeBps;

        emit StrategyUpdated(
            strategyId,
            msg.sender,
            keccak256("fees"),
            abi.encode(newBaseFeeBps, newCuratorFeeBps)
        );
    }

    function updateStrategyTopics(
        bytes32 strategyId,
        bytes32 newPrimaryTopic,
        bytes32 newSecondaryTopic
    ) external {
        StrategyConfig storage cfg = strategies[strategyId];
        if (cfg.owner == address(0)) revert InitFurnaca_StrategyUnknown();
        if (msg.sender != cfg.owner && !isStrategyCurator[msg.sender]) {
            revert InitFurnaca_Unauthorized();
        }

        cfg.primaryTopic = newPrimaryTopic;
        cfg.secondaryTopic = newSecondaryTopic;

        emit StrategyUpdated(
            strategyId,
            msg.sender,
            keccak256("topics"),
            abi.encode(newPrimaryTopic, newSecondaryTopic)
        );
    }

    // -------------------------------------------------------------------------
    // Sentiment and oracle helpers
    // -------------------------------------------------------------------------
