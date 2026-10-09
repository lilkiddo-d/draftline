// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Guarded} from "../access/Guarded.sol";
import {IProjectTokenHooks} from "../interfaces/IDraftline.sol";

/// @title FeeCollector
/// @notice Receives protocol fees from every pool. `distribute` (permissionless) sends `stakerShareBps` of
///         the reward token to $DRFT backstop stakers when the project token is live and staked, and the
///         rest (or everything, before the token exists) to the treasury.
contract FeeCollector is Guarded, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_STAKER_SHARE_BPS = 8_000;

    address public immutable rewardToken;
    address public treasury;
    IProjectTokenHooks public hooks;
    uint16 public stakerShareBps;

    event Distributed(address indexed token, uint256 toTreasury, uint256 toStakers);
    event TreasurySet(address treasury);
    event HooksSet(address hooks);
    event StakerShareSet(uint16 bps);

    error BadBps();

    constructor(address admin, address guardian, address rewardToken_, address treasury_, uint16 stakerShareBps_)
        Guarded(admin, guardian)
    {
        if (rewardToken_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (stakerShareBps_ > MAX_STAKER_SHARE_BPS) revert BadBps();
        rewardToken = rewardToken_;
        treasury = treasury_;
        stakerShareBps = stakerShareBps_;
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setHooks(IProjectTokenHooks hooks_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hooks = hooks_;
        emit HooksSet(address(hooks_));
    }

    function setStakerShareBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_STAKER_SHARE_BPS) revert BadBps();
        stakerShareBps = bps;
        emit StakerShareSet(bps);
    }

    function distribute(address token) external nonReentrant whenNotPaused {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < 1) return;
        uint256 toStakers = 0;
        IProjectTokenHooks h = hooks;
        if (token == rewardToken && address(h) != address(0) && h.canReceiveRewards()) {
            toStakers = (balance * stakerShareBps) / BPS;
        }
        uint256 toTreasury = balance - toStakers;
        emit Distributed(token, toTreasury, toStakers);
        if (toStakers != 0) {
            IERC20(token).safeTransfer(address(h), toStakers);
            h.notifyRewards(toStakers);
        }
        if (toTreasury != 0) IERC20(token).safeTransfer(treasury, toTreasury);
    }
}
