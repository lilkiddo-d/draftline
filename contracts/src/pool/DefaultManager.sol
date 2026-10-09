// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICreditPool, IPoolRegistry, IProjectTokenHooks} from "../interfaces/IDraftline.sol";

/// @title DefaultManager
/// @notice Late/default policy for every pool. Marking a loan past due and triggering a time-based default
///         are permissionless (keepers, lenders, anyone) so loss recognition never depends on a trusted party.
///         The pool delegate or governance may declare an early default (e.g. confirmed fraud). After any
///         write-down that reaches senior, the $DRFT staking backstop is asked to cover it; a backstop
///         failure can never block a default.
/// @dev Deliberately not pausable: loss recognition protects lenders and must stay available.
contract DefaultManager is AccessControl, ReentrancyGuard {
    IPoolRegistry public poolRegistry;
    IProjectTokenHooks public hooks;

    event PoolRegistrySet(address registry);
    event HooksSet(address hooks);
    event DefaultTriggered(address indexed pool, uint256 indexed tokenId, address indexed by, bool early);
    event BackstopCovered(address indexed pool, uint256 indexed tokenId, uint256 seniorLoss, uint256 slashed);
    event BackstopFailed(address indexed pool, uint256 indexed tokenId, uint256 seniorLoss);

    error ZeroAddress();
    error AlreadySet();
    error UnknownPool(address pool);
    error NotDefaultable(uint256 defaultableAt);
    error Unauthorized();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setPoolRegistry(IPoolRegistry registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(poolRegistry) != address(0)) revert AlreadySet();
        if (address(registry) == address(0)) revert ZeroAddress();
        poolRegistry = registry;
        emit PoolRegistrySet(address(registry));
    }

    /// @notice address(0) disables backstop calls.
    function setHooks(IProjectTokenHooks hooks_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hooks = hooks_;
        emit HooksSet(address(hooks_));
    }

    function markPastDue(address pool, uint256 tokenId) external {
        _requirePool(pool);
        ICreditPool(pool).markPastDue(tokenId);
    }

    /// @notice Anyone may default a loan once dueDate + gracePeriod + defaultWindow has passed.
    function triggerDefault(address pool, uint256 tokenId) external nonReentrant {
        _requirePool(pool);
        uint256 at = ICreditPool(pool).defaultableAt(tokenId);
        if (block.timestamp < at) revert NotDefaultable(at);
        _default(pool, tokenId, false);
    }

    /// @notice Early default by the pool's delegate or governance (fraud, insolvency, confirmed dispute).
    function declareDefault(address pool, uint256 tokenId) external nonReentrant {
        _requirePool(pool);
        if (msg.sender != ICreditPool(pool).delegate() && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        _default(pool, tokenId, true);
    }

    function _default(address pool, uint256 tokenId, bool early) private {
        emit DefaultTriggered(pool, tokenId, msg.sender, early);
        uint256 seniorLoss = ICreditPool(pool).writeOff(tokenId);
        IProjectTokenHooks h = hooks;
        if (seniorLoss == 0 || address(h) == address(0)) return;
        try h.coverSeniorLoss(pool, tokenId, seniorLoss) returns (uint256 slashed) {
            emit BackstopCovered(pool, tokenId, seniorLoss, slashed);
        } catch {
            emit BackstopFailed(pool, tokenId, seniorLoss);
        }
    }

    function _requirePool(address pool) private view {
        IPoolRegistry r = poolRegistry;
        if (address(r) == address(0) || !r.isPool(pool)) revert UnknownPool(pool);
    }
}
