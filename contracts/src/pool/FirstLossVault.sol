// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICreditPool} from "../interfaces/IDraftline.sol";

/// @title FirstLossVault
/// @notice Holds the Pool Delegate's first-loss stake in the pool asset. Slashed before the junior tranche
///         on every default. The stake belongs to the pool's *current* delegate: if governance replaces a
///         delegate for cause, the stake stays behind as cover. Delegate fees are credited here.
contract FirstLossVault is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ICreditPool public pool;
    IERC20 public asset;
    uint256 public stake;

    event StakeDeposited(address indexed from, uint256 amount);
    event StakeWithdrawn(address indexed delegate, address indexed to, uint256 amount);
    event StakeSlashed(uint256 amount);
    event StakeCredited(uint256 amount);

    error Unauthorized();
    error ZeroAmount();
    error ZeroAddress();
    error PoolInactive();
    error PoolImpaired();
    error BelowRequirement(uint256 remaining, uint256 required);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(ICreditPool pool_, IERC20 asset_) external initializer {
        if (address(pool_) == address(0) || address(asset_) == address(0)) revert ZeroAddress();
        pool = pool_;
        asset = asset_;
    }

    modifier onlyPool() {
        if (msg.sender != address(pool)) revert Unauthorized();
        _;
    }

    /// @notice Anyone may top up the stake (typically the delegate).
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        stake += amount;
        emit StakeDeposited(msg.sender, amount);
        asset.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Delegate withdraws excess stake. Blocked while the pool is paused or impaired (a loan is past
    ///         due) so a delegate cannot pull cover ahead of a default they can see coming.
    function withdraw(uint256 amount, address to) external nonReentrant {
        if (msg.sender != pool.delegate()) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (!pool.isActive()) revert PoolInactive();
        if (pool.isImpaired()) revert PoolImpaired();
        uint256 remaining = stake - amount;
        uint256 required = pool.requiredFirstLoss();
        if (remaining < required) revert BelowRequirement(remaining, required);
        stake = remaining;
        emit StakeWithdrawn(msg.sender, to, amount);
        asset.safeTransfer(to, amount);
    }

    function slash(uint256 amount) external onlyPool nonReentrant returns (uint256 slashed) {
        slashed = amount < stake ? amount : stake;
        stake -= slashed;
        emit StakeSlashed(slashed);
        asset.safeTransfer(address(pool), slashed);
    }

    /// @notice Pool credits recovery proceeds or delegate fees it has already transferred in.
    function notifyDeposit(uint256 amount) external onlyPool {
        stake += amount;
        emit StakeCredited(amount);
    }
}
