// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICreditPool, ITranche} from "../interfaces/IDraftline.sol";

/// @title EpochRedemptions
/// @notice Epoch-based exit queue for both tranches. Lenders escrow shares during an epoch; once the epoch
///         has elapsed anyone (the keeper) closes it. Senior requests are filled first from idle cash, junior
///         only down to the required subordination. Partial fills are pro-rata; unfilled shares are returned.
///         Escrowed shares keep bearing losses until processed, and epochs cannot close while the pool is
///         impaired, so a "known default" cannot be front-run by redemption.
/// @dev Every operation is O(1); per-user results are computed lazily on claim.
contract EpochRedemptions is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct EpochData {
        uint256 requested;
        uint256 fulfilled;
        uint256 assets;
        bool processed;
    }

    struct Request {
        uint256 epoch;
        uint256 shares;
    }

    ICreditPool public pool;
    IERC20 public asset;
    ITranche public seniorTranche;
    ITranche public juniorTranche;
    uint64 public epochDuration;
    uint64 public epochStart;
    uint256 public currentEpoch;

    mapping(uint256 => mapping(uint256 => EpochData)) internal _epochs; // [epoch][SENIOR_IDX|JUNIOR_IDX]
    mapping(address => mapping(bool => Request)) internal _requests;

    event RedeemRequested(address indexed account, bool indexed senior, uint256 indexed epoch, uint256 shares);
    event RedeemCancelled(address indexed account, bool indexed senior, uint256 indexed epoch, uint256 shares);
    event RedeemClaimed(
        address indexed account, bool indexed senior, uint256 indexed epoch, uint256 assets, uint256 sharesReturned
    );
    event EpochProcessed(bool indexed senior, uint256 indexed epoch, uint256 requested, uint256 fulfilled, uint256 assets);
    event EpochClosed(uint256 indexed epoch, uint64 nextEpochStart);

    error ZeroAddress();
    error ZeroAmount();
    error PoolInactive();
    error PoolImpaired();
    error EpochNotOver(uint256 endsAt);
    error NothingToClaim();
    error NotCancellable();
    error BadDuration();
    error PlanMismatch();

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SENIOR_IDX = 0;
    uint256 internal constant JUNIOR_IDX = 1;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(ICreditPool pool_, ITranche senior_, ITranche junior_, IERC20 asset_, uint64 duration)
        external
        initializer
    {
        if (
            address(pool_) == address(0) || address(senior_) == address(0) || address(junior_) == address(0)
                || address(asset_) == address(0)
        ) revert ZeroAddress();
        if (duration < 1 hours || duration > 90 days) revert BadDuration();
        pool = pool_;
        seniorTranche = senior_;
        juniorTranche = junior_;
        asset = asset_;
        epochDuration = duration;
        epochStart = uint64(block.timestamp);
    }

    // ---------------------------------------------------------------- lender actions

    function requestRedeem(bool senior, uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (!pool.isActive()) revert PoolInactive();
        Request storage r = _requests[msg.sender][senior];
        if (r.shares != 0 && r.epoch != currentEpoch) _claim(msg.sender, senior);
        uint256 epoch = currentEpoch;
        r.epoch = epoch;
        r.shares += shares;
        _epochs[epoch][_idx(senior)].requested += shares;
        emit RedeemRequested(msg.sender, senior, epoch, shares);
        IERC20(address(_tranche(senior))).safeTransferFrom(msg.sender, address(this), shares);
    }

    function cancelRequest(bool senior) external nonReentrant {
        Request storage r = _requests[msg.sender][senior];
        uint256 shares = r.shares;
        if (shares == 0 || r.epoch != currentEpoch) revert NotCancellable();
        _epochs[r.epoch][_idx(senior)].requested -= shares;
        emit RedeemCancelled(msg.sender, senior, r.epoch, shares);
        delete _requests[msg.sender][senior];
        IERC20(address(_tranche(senior))).safeTransfer(msg.sender, shares);
    }

    function claim(bool senior) external nonReentrant {
        _claim(msg.sender, senior);
    }

    // ---------------------------------------------------------------- keeper

    /// @notice Close the current epoch once its duration has elapsed. Permissionless.
    function closeEpoch() external nonReentrant {
        uint256 endsAt = uint256(epochStart) + epochDuration;
        if (block.timestamp < endsAt) revert EpochNotOver(endsAt);
        if (!pool.isActive()) revert PoolInactive();
        if (pool.isImpaired()) revert PoolImpaired();
        uint256 epoch = currentEpoch;
        // Checks-effects-interactions: plan both fills from pool state, record everything, then execute.
        // Senior is planned first; junior is planned against the post-senior state.
        (uint256 sShares, uint256 sAssets, uint256 jShares, uint256 jAssets) = previewClose();
        _record(epoch, true, sShares, sAssets);
        _record(epoch, false, jShares, jAssets);
        currentEpoch = epoch + 1;
        epochStart = uint64(block.timestamp);
        emit EpochClosed(epoch, uint64(block.timestamp));
        if (sShares > 0 && pool.executeRedemption(true, sShares) != sAssets) revert PlanMismatch();
        if (jShares > 0 && pool.executeRedemption(false, jShares) != jAssets) revert PlanMismatch();
    }

    /// @notice What closing the current epoch right now would fill (shares, assets) for each tranche.
    function previewClose()
        public
        view
        returns (uint256 sShares, uint256 sAssets, uint256 jShares, uint256 jAssets)
    {
        uint256 epoch = currentEpoch;
        uint256 cash = pool.cash();
        uint256 s = pool.seniorAssets();
        (sShares, sAssets) = _fill(seniorTranche, _epochs[epoch][SENIOR_IDX].requested, Math.min(cash, s));
        cash -= sAssets;
        s -= sAssets;
        uint256 r = pool.maxSeniorRatioBps();
        uint256 minJunior = 0;
        if (s > 0) minJunior = r > 0 ? Math.mulDiv(s, BPS - r, r, Math.Rounding.Ceil) : type(uint256).max;
        uint256 j = pool.juniorAssets();
        uint256 free = j > minJunior ? j - minJunior : 0;
        (jShares, jAssets) = _fill(juniorTranche, _epochs[epoch][JUNIOR_IDX].requested, Math.min(cash, free));
    }

    // ---------------------------------------------------------------- views

    function epochData(uint256 epoch, bool senior) external view returns (EpochData memory) {
        return _epochs[epoch][_idx(senior)];
    }

    function requestOf(address account, bool senior) external view returns (Request memory) {
        return _requests[account][senior];
    }

    function epochEndsAt() external view returns (uint256) {
        return uint256(epochStart) + epochDuration;
    }

    /// @notice What `account` would receive by claiming now (0,0 if the request is still pending).
    function claimable(address account, bool senior) public view returns (uint256 assets, uint256 sharesReturned) {
        Request storage r = _requests[account][senior];
        if (r.shares == 0 || r.epoch >= currentEpoch) return (0, 0);
        EpochData storage e = _epochs[r.epoch][_idx(senior)];
        assets = Math.mulDiv(r.shares, e.assets, e.requested);
        sharesReturned = Math.mulDiv(r.shares, e.requested - e.fulfilled, e.requested);
    }

    // ---------------------------------------------------------------- internals

    function _fill(ITranche tranche, uint256 requested, uint256 maxAssets)
        private
        view
        returns (uint256 shares, uint256 assets)
    {
        if (requested < 1) return (0, 0);
        shares = requested;
        if (tranche.convertToAssets(requested) > maxAssets) {
            shares = Math.min(tranche.convertToShares(maxAssets), requested);
        }
        assets = tranche.convertToAssets(shares);
    }

    function _record(uint256 epoch, bool senior, uint256 shares, uint256 assets) private {
        EpochData storage e = _epochs[epoch][_idx(senior)];
        e.processed = true;
        e.fulfilled = shares;
        e.assets = assets;
        emit EpochProcessed(senior, epoch, e.requested, shares, assets);
    }

    function _claim(address account, bool senior) private {
        (uint256 assets, uint256 sharesReturned) = claimable(account, senior);
        Request storage r = _requests[account][senior];
        uint256 epoch = r.epoch;
        if (r.shares == 0 || epoch >= currentEpoch) revert NothingToClaim();
        delete _requests[account][senior];
        emit RedeemClaimed(account, senior, epoch, assets, sharesReturned);
        if (assets != 0) asset.safeTransfer(account, assets);
        if (sharesReturned != 0) IERC20(address(_tranche(senior))).safeTransfer(account, sharesReturned);
    }

    function _idx(bool senior) private pure returns (uint256) {
        return senior ? SENIOR_IDX : JUNIOR_IDX;
    }

    function _tranche(bool senior) private view returns (ITranche) {
        return senior ? seniorTranche : juniorTranche;
    }
}
