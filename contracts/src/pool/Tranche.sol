// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICreditPool} from "../interfaces/IDraftline.sol";

/// @title Tranche
/// @notice ERC-4626 share token for the Senior or Junior tranche of a CreditPool. Assets are custodied by
///         the pool; `totalAssets()` is the tranche's book NAV in the pool. Deposits are instant; exits are
///         epoch-based only (via EpochRedemptions), so `withdraw`/`redeem` are disabled.
contract Tranche is Initializable, ERC4626Upgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ICreditPool public pool;
    address public epochRedemptions;
    bool public isSenior;

    error Unauthorized();
    error UseEpochRedemptions();
    error NotCompliant(address account);
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 asset_,
        ICreditPool pool_,
        address epochRedemptions_,
        bool senior_,
        string calldata name_,
        string calldata symbol_
    ) external initializer {
        if (address(asset_) == address(0) || address(pool_) == address(0) || epochRedemptions_ == address(0)) {
            revert ZeroAddress();
        }
        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        pool = pool_;
        epochRedemptions = epochRedemptions_;
        isSenior = senior_;
    }

    // ---------------------------------------------------------------- ERC-4626

    function totalAssets() public view override returns (uint256) {
        return pool.trancheAssets(isSenior);
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        return pool.maxDeposit(isSenior, receiver);
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert UseEpochRedemptions();
    }

    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert UseEpochRedemptions();
    }

    /// @notice Pool burns shares that EpochRedemptions has fulfilled.
    function burnFrom(address account, uint256 shares) external {
        if (msg.sender != address(pool)) revert Unauthorized();
        _burn(account, shares);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Assets go straight to the pool, which validates caps/compliance and books the deposit.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        IERC20(asset()).safeTransferFrom(caller, address(pool), assets);
        pool.recordDeposit(isSenior, caller, receiver, assets);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev 6 extra share decimals: defends against share-price inflation/rounding griefing.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev Share transfers respect lender compliance (KYC when enabled, sanctions always). The redemption
    ///      escrow is exempt so queued shares can always be returned.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && to != epochRedemptions && from != epochRedemptions) {
            if (!pool.canHoldShares(to)) revert NotCompliant(to);
        }
        super._update(from, to, value);
    }
}
