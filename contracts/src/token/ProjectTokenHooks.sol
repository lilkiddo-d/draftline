// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Guarded} from "../access/Guarded.sol";
import {IOracleAdapter} from "../interfaces/IDraftline.sol";

/// @title ProjectTokenHooks
/// @notice Every $DRFT feature lives here, and all of it is inert until governance (Timelock) calls
///         `setProjectToken` exactly once. Draftline never deploys the token itself.
///
///         Backstop staking: $DRFT stakers form a protocol-wide backstop. When a default reaches the senior
///         tranche (after first-loss and junior are exhausted), up to `maxSlashBps` of the staked $DRFT,
///         valued via OracleAdapter, is slashed to the `liquidator` (governance), which sells it and pays the
///         proceeds back into the pool through `CreditPool.recover` — restoring senior first.
///         In return stakers earn `FeeCollector.stakerShareBps` of protocol fees in the pool asset.
///
///         Stakes are share-based so slashing is O(1) and pro-rata. Unstaking needs a cooldown, during which
///         the stake remains slashable (no exit ahead of a known default).
contract ProjectTokenHooks is Guarded, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 private constant PRECISION = 1e36;
    uint256 private constant VIRTUAL_SHARES = 1e3;
    uint16 public constant MAX_SLASH_BPS = 5_000;
    uint64 public constant MAX_COOLDOWN = 90 days;

    struct Cooldown {
        uint256 shares;
        uint64 unlockAt;
    }

    IERC20 public projectToken;
    IERC20 public immutable rewardToken;
    IOracleAdapter public oracle;
    address public defaultManager;
    address public feeCollector;
    address public liquidator;
    uint64 public cooldownPeriod = 14 days;
    uint16 public maxSlashBps = 3_000;

    uint256 public totalShares;
    uint256 public totalStaked;
    uint256 public rewardPerShare;
    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public pendingRewards;
    mapping(address => Cooldown) public cooldowns;

    event ProjectTokenSet(address indexed token);
    event Staked(address indexed account, uint256 amount, uint256 shares);
    event UnstakeRequested(address indexed account, uint256 shares, uint64 unlockAt);
    event Unstaked(address indexed account, uint256 shares, uint256 amount);
    event RewardsNotified(uint256 amount);
    event RewardsClaimed(address indexed account, uint256 amount);
    event BackstopSlashed(address indexed pool, uint256 indexed tokenId, uint256 seniorLoss, uint256 slashed, uint256 price);
    event ConfigSet(address oracle, address defaultManager, address feeCollector, address liquidator);
    event RiskParamsSet(uint64 cooldownPeriod, uint16 maxSlashBps);

    error TokenAlreadySet();
    error TokenNotSet();
    error InvalidToken();
    error Unauthorized();
    error ZeroAmount();
    error InsufficientShares();
    error CooldownActive(uint64 unlockAt);
    error BadParams();

    constructor(address admin, address guardian, IERC20 rewardToken_, IOracleAdapter oracle_, address liquidator_)
        Guarded(admin, guardian)
    {
        if (address(rewardToken_) == address(0) || liquidator_ == address(0)) revert ZeroAddress();
        rewardToken = rewardToken_;
        oracle = oracle_;
        liquidator = liquidator_;
    }

    // ================================================================== governance

    /// @notice One-time activation of every $DRFT feature. Callable only by the admin (the 48h Timelock).
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(projectToken) != address(0)) revert TokenAlreadySet();
        if (token == address(0) || token.code.length == 0 || token == address(rewardToken)) revert InvalidToken();
        projectToken = IERC20(token);
        emit ProjectTokenSet(token);
    }

    function setConfig(IOracleAdapter oracle_, address defaultManager_, address feeCollector_, address liquidator_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (liquidator_ == address(0)) revert ZeroAddress();
        oracle = oracle_;
        defaultManager = defaultManager_;
        feeCollector = feeCollector_;
        liquidator = liquidator_;
        emit ConfigSet(address(oracle_), defaultManager_, feeCollector_, liquidator_);
    }

    function setRiskParams(uint64 cooldown, uint16 slashBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cooldown > MAX_COOLDOWN || slashBps > MAX_SLASH_BPS) revert BadParams();
        cooldownPeriod = cooldown;
        maxSlashBps = slashBps;
        emit RiskParamsSet(cooldown, slashBps);
    }

    // ================================================================== staking

    function isActive() public view returns (bool) {
        return address(projectToken) != address(0);
    }

    function stake(uint256 amount) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (!isActive()) revert TokenNotSet();
        if (amount == 0) revert ZeroAmount();
        _settle(msg.sender);
        shares = Math.mulDiv(amount, totalShares + VIRTUAL_SHARES, totalStaked + 1);
        if (shares == 0) revert ZeroAmount();
        totalShares += shares;
        totalStaked += amount;
        sharesOf[msg.sender] += shares;
        rewardDebt[msg.sender] = Math.mulDiv(sharesOf[msg.sender], rewardPerShare, PRECISION);
        emit Staked(msg.sender, amount, shares);
        projectToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Start (or extend) the cooldown for `shares`. Shares stay slashable and keep earning.
    function requestUnstake(uint256 shares) external {
        if (shares == 0) revert ZeroAmount();
        Cooldown storage c = cooldowns[msg.sender];
        if (c.shares + shares > sharesOf[msg.sender]) revert InsufficientShares();
        c.shares += shares;
        c.unlockAt = uint64(block.timestamp) + cooldownPeriod;
        emit UnstakeRequested(msg.sender, c.shares, c.unlockAt);
    }

    function unstake() external nonReentrant whenNotPaused returns (uint256 amount) {
        Cooldown memory c = cooldowns[msg.sender];
        if (c.shares == 0) revert ZeroAmount();
        if (block.timestamp < c.unlockAt) revert CooldownActive(c.unlockAt);
        _settle(msg.sender);
        amount = stakedBalanceOfShares(c.shares);
        delete cooldowns[msg.sender];
        totalShares -= c.shares;
        totalStaked -= amount;
        sharesOf[msg.sender] -= c.shares;
        rewardDebt[msg.sender] = Math.mulDiv(sharesOf[msg.sender], rewardPerShare, PRECISION);
        emit Unstaked(msg.sender, c.shares, amount);
        projectToken.safeTransfer(msg.sender, amount);
    }

    function claimRewards() external nonReentrant returns (uint256 amount) {
        _settle(msg.sender);
        amount = pendingRewards[msg.sender];
        if (amount == 0) return 0;
        pendingRewards[msg.sender] = 0;
        emit RewardsClaimed(msg.sender, amount);
        rewardToken.safeTransfer(msg.sender, amount);
    }

    // ================================================================== protocol hooks

    function canReceiveRewards() external view returns (bool) {
        return isActive() && totalShares != 0;
    }

    /// @notice FeeCollector has transferred `amount` of rewardToken in; credit it to stakers.
    function notifyRewards(uint256 amount) external {
        if (msg.sender != feeCollector) revert Unauthorized();
        if (totalShares == 0) revert InsufficientShares();
        rewardPerShare += Math.mulDiv(amount, PRECISION, totalShares);
        emit RewardsNotified(amount);
    }

    /// @notice Called by DefaultManager when a default writes down senior NAV. Returns $DRFT slashed.
    ///         Never reverts for "can't cover" conditions (token unset, no stake, no price) — returns 0.
    function coverSeniorLoss(address pool, uint256 tokenId, uint256 lossAssets)
        external
        nonReentrant
        returns (uint256 slashed)
    {
        if (msg.sender != defaultManager) revert Unauthorized();
        if (!isActive() || totalStaked == 0 || lossAssets == 0 || address(oracle) == address(0)) return 0;
        (bool okAsset, uint256 assetPrice) = oracle.tryGetPrice(address(rewardToken));
        (bool okToken, uint256 tokenPrice) = oracle.tryGetPrice(address(projectToken));
        if (!okAsset || !okToken || tokenPrice == 0) return 0;

        uint8 assetDecimals = IERC20Metadata(address(rewardToken)).decimals();
        uint8 tokenDecimals = IERC20Metadata(address(projectToken)).decimals();
        // USD value of the loss (1e18) -> amount of $DRFT at the oracle price.
        uint256 lossUsd = Math.mulDiv(lossAssets, assetPrice, 10 ** assetDecimals);
        uint256 tokensNeeded = Math.mulDiv(lossUsd, 10 ** tokenDecimals, tokenPrice);
        uint256 cap = (totalStaked * maxSlashBps) / BPS;
        slashed = Math.min(tokensNeeded, cap);
        if (slashed == 0) return 0;
        totalStaked -= slashed;
        emit BackstopSlashed(pool, tokenId, lossAssets, slashed, tokenPrice);
        projectToken.safeTransfer(liquidator, slashed);
    }

    // ================================================================== views

    function stakedBalanceOfShares(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, totalStaked + 1, totalShares + VIRTUAL_SHARES);
    }

    function stakedBalance(address account) external view returns (uint256) {
        return stakedBalanceOfShares(sharesOf[account]);
    }

    function earned(address account) public view returns (uint256) {
        return pendingRewards[account] + Math.mulDiv(sharesOf[account], rewardPerShare, PRECISION) - rewardDebt[account];
    }

    // ================================================================== internals

    function _settle(address account) private {
        pendingRewards[account] = earned(account);
        rewardDebt[account] = Math.mulDiv(sharesOf[account], rewardPerShare, PRECISION);
    }
}
