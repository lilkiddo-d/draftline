// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AggregatorV3Interface} from "../interfaces/IDraftline.sol";

/// @title OracleAdapter
/// @notice Token -> USD price (1e18 scaled) from any AggregatorV3-compatible source. On Robinhood Chain the
///         sources are Chainlink feeds; any custom source (e.g. a TWAP wrapper for $DRFT) is swappable by
///         governance as long as it implements AggregatorV3Interface. An L2 sequencer-uptime feed is optional
///         (none is published for Robinhood Chain yet — see config/chains.ts).
contract OracleAdapter is AccessControl {
    struct FeedConfig {
        AggregatorV3Interface feed;
        uint32 heartbeat; // max age of an answer in seconds
        uint8 decimals;
    }

    uint32 public constant MAX_HEARTBEAT = 7 days;

    mapping(address => FeedConfig) public feeds;
    AggregatorV3Interface public sequencerUptimeFeed;
    uint32 public sequencerGracePeriod;

    event FeedSet(address indexed token, address feed, uint32 heartbeat, uint8 decimals);
    event SequencerFeedSet(address feed, uint32 gracePeriod);

    error ZeroAddress();
    error NoFeed(address token);
    error BadHeartbeat();
    error InvalidPrice(address token);
    error StalePrice(address token, uint256 updatedAt);
    error SequencerDown();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setFeed(address token, AggregatorV3Interface feed, uint32 heartbeat)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0)) revert ZeroAddress();
        if (address(feed) == address(0)) {
            delete feeds[token];
            emit FeedSet(token, address(0), 0, 0);
            return;
        }
        if (heartbeat == 0 || heartbeat > MAX_HEARTBEAT) revert BadHeartbeat();
        uint8 dec = feed.decimals();
        feeds[token] = FeedConfig(feed, heartbeat, dec);
        emit FeedSet(token, address(feed), heartbeat, dec);
    }

    function setSequencerUptimeFeed(AggregatorV3Interface feed, uint32 gracePeriod)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(address(feed), gracePeriod);
    }

    /// @notice Reverting price read. Returns USD per 1 whole token, scaled to 1e18.
    function getPrice(address token) public view returns (uint256) {
        _checkSequencer();
        FeedConfig memory cfg = feeds[token];
        if (address(cfg.feed) == address(0)) revert NoFeed(token);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            cfg.feed.latestRoundData();
        if (answer <= 0 || startedAt > updatedAt || answeredInRound < roundId) revert InvalidPrice(token);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > cfg.heartbeat) {
            revert StalePrice(token, updatedAt);
        }
        return _scale(uint256(answer), cfg.decimals);
    }

    /// @notice Non-reverting variant used by loss-path code that must never be blocked by an oracle.
    function tryGetPrice(address token) external view returns (bool ok, uint256 price) {
        try this.getPrice(token) returns (uint256 p) {
            return (true, p);
        } catch {
            return (false, 0);
        }
    }

    function _checkSequencer() private view {
        AggregatorV3Interface seq = sequencerUptimeFeed;
        if (address(seq) == address(0)) return;
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            seq.latestRoundData();
        // answer 0: up, 1: down. Require a grace period after it comes back up.
        if (
            answer > 0 || answer < 0 || startedAt < 1 || updatedAt < startedAt || answeredInRound < roundId
                || block.timestamp - startedAt <= sequencerGracePeriod
        ) {
            revert SequencerDown();
        }
    }

    function _scale(uint256 value, uint8 dec) private pure returns (uint256) {
        if (dec == 18) return value;
        if (dec < 18) return value * 10 ** (18 - dec);
        return value / 10 ** (dec - 18);
    }
}
