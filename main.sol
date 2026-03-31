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
