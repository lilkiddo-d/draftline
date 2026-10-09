// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    IComplianceRegistry,
    IUnderwriting,
    IPoolRegistry,
    IInvoiceNFT,
    ITranche,
    IFirstLossVault
} from "../interfaces/IDraftline.sol";
import {InvoiceStatus, LoanStatus, PoolParams} from "../libraries/Types.sol";
import {Waterfall} from "../libraries/Waterfall.sol";
import {PoolParamsLib} from "../libraries/PoolParamsLib.sol";

/// @title CreditPool
/// @notice Book-value accounting for one invoice-financing pool with a Senior and Junior ERC-4626 tranche.
///         Invariant: seniorAssets + juniorAssets == cash + outstandingPrincipal.
///         Cash is tracked internally (donations are ignored), interest is recognised on receipt only, and
///         every loss is allocated first-loss -> junior -> senior via the Waterfall library.
///         Roles are read from the PoolFactory's AccessControl: its DEFAULT_ADMIN_ROLE (the Timelock) administers
///         every pool and its GUARDIAN_ROLE can pause any pool.
contract CreditPool is Initializable, PausableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    uint256 public constant BPS = 10_000;
    uint256 public constant YEAR = 365 days;
    uint256 public constant MAX_ACTIVE_LOANS = 250;

    struct Loan {
        address borrower;
        LoanStatus status;
        uint64 fundedAt;
        uint64 dueDate;
        bool lateFeeCharged;
        uint128 principal;
        uint128 principalOwed;
        uint128 feeOwed;
        uint128 recovered;
        bytes32 attestation;
    }

    struct LossStats {
        uint128 defaults;
        uint128 totalWrittenOff;
        uint128 firstLossAbsorbed;
        uint128 juniorAbsorbed;
        uint128 seniorAbsorbed;
        uint128 recovered;
    }

    struct InitParams {
        address delegate;
        address asset;
        address seniorTranche;
        address juniorTranche;
        address firstLossVault;
        address epochRedemptions;
        address invoiceNFT;
        address compliance;
        address underwriting;
        address factory;
        address defaultManager;
        address feeCollector;
        string name;
        PoolParams params;
    }

    // ------------------------------------------------------------------ wiring
    IERC20 public asset;
    ITranche public seniorTranche;
    ITranche public juniorTranche;
    IFirstLossVault public firstLossVault;
    address public epochRedemptions;
    IInvoiceNFT public invoiceNFT;
    IComplianceRegistry public compliance;
    IUnderwriting public underwriting;
    IPoolRegistry public factory;
    address public defaultManager;
    address public feeCollector;
    address public delegate;
    string public name;
    PoolParams internal _params;

    // ------------------------------------------------------------------ accounting
    uint256 public seniorAssets;
    uint256 public juniorAssets;
    uint256 public cash;
    uint256 public outstandingPrincipal;
    uint256 public seniorInterestOwed;
    uint256 public juniorInterestOwed;
    uint256 public seniorWritedown;
    uint256 public juniorWritedown;
    uint256 public firstLossWritedown;
    uint64 public lastAccrual;
    uint64 public createdAt;
    LossStats public lossStats;

    mapping(uint256 => Loan) internal _loans;
    EnumerableSet.UintSet internal _activeLoans;
    mapping(address => bool) public approvedBorrower;
    mapping(address => uint256) public borrowerLimit;
    mapping(address => uint256) public borrowerOutstanding;

    // ------------------------------------------------------------------ events
    event ParamsUpdated(PoolParams params);
    event DelegateChanged(address indexed previous, address indexed next);
    event BorrowerApproved(address indexed borrower, uint256 limit);
    event BorrowerRevoked(address indexed borrower);
    event InvoiceSubmitted(uint256 indexed tokenId, address indexed borrower);
    event InvoiceReleased(uint256 indexed tokenId, address indexed borrower, bool byDelegate);
    event InvoiceFunded(
        uint256 indexed tokenId, address indexed borrower, uint256 advance, uint256 fee, uint64 dueDate, bytes32 attestation
    );
    event Repayment(uint256 indexed tokenId, address indexed payer, uint256 feePaid, uint256 principalPaid);
    event LoanRepaid(uint256 indexed tokenId);
    event LoanPastDue(uint256 indexed tokenId);
    event LateFeeCharged(uint256 indexed tokenId, uint256 amount);
    event LoanDefaulted(
        uint256 indexed tokenId, uint256 loss, uint256 firstLoss, uint256 juniorLoss, uint256 seniorLoss
    );
    event Recovery(
        uint256 indexed tokenId,
        address indexed payer,
        uint256 amount,
        uint256 toSenior,
        uint256 toJunior,
        uint256 toFirstLoss,
        uint256 excess
    );
    event IncomeDistributed(
        uint256 amount, uint256 senior, uint256 juniorHurdle, uint256 juniorResidual, uint256 protocol, uint256 delegateFee
    );
    event InterestAccrued(uint256 seniorOwed, uint256 juniorOwed);
    event Deposited(bool indexed senior, address indexed caller, address indexed receiver, uint256 assets);
    event Redeemed(bool indexed senior, uint256 shares, uint256 assets);

    // ------------------------------------------------------------------ errors
    error ZeroAddress();
    error InvalidParams();
    error Unauthorized();
    error PoolInactive();
    error NotCompliant(address account);
    error BorrowerNotApproved(address borrower);
    error BadLoanStatus(LoanStatus status);
    error BadInvoice();
    error AdvanceTooHigh();
    error FeeTooHigh();
    error TenorTooLong();
    error InsufficientCash();
    error LimitExceeded();
    error ConcentrationExceeded();
    error InsufficientFirstLoss();
    error TooManyLoans();
    error NotPastDue();
    error DepositTooLarge();
    error ZeroAmount();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        if (
            p.delegate == address(0) || p.asset == address(0)
                || p.seniorTranche == address(0) || p.juniorTranche == address(0) || p.firstLossVault == address(0)
                || p.epochRedemptions == address(0) || p.invoiceNFT == address(0) || p.compliance == address(0)
                || p.underwriting == address(0) || p.factory == address(0) || p.defaultManager == address(0)
                || p.feeCollector == address(0)
        ) revert ZeroAddress();
        __Pausable_init();

        asset = IERC20(p.asset);
        seniorTranche = ITranche(p.seniorTranche);
        juniorTranche = ITranche(p.juniorTranche);
        firstLossVault = IFirstLossVault(p.firstLossVault);
        epochRedemptions = p.epochRedemptions;
        invoiceNFT = IInvoiceNFT(p.invoiceNFT);
        compliance = IComplianceRegistry(p.compliance);
        underwriting = IUnderwriting(p.underwriting);
        factory = IPoolRegistry(p.factory);
        defaultManager = p.defaultManager;
        feeCollector = p.feeCollector;
        delegate = p.delegate;
        name = p.name;
        _setParams(p.params);
        lastAccrual = uint64(block.timestamp);
        createdAt = uint64(block.timestamp);
    }

    // ================================================================== modifiers

    modifier whenActive() {
        if (!isActive()) revert PoolInactive();
        _;
    }

    modifier onlyDelegate() {
        if (msg.sender != delegate || !underwriting.isActiveDelegate(msg.sender)) revert Unauthorized();
        _;
    }

    modifier onlyRole(bytes32 role) {
        if (!IAccessControl(address(factory)).hasRole(role, msg.sender)) revert Unauthorized();
        _;
    }

    modifier onlyDefaultManager() {
        if (msg.sender != defaultManager) revert Unauthorized();
        _;
    }

    // ================================================================== admin (Timelock) / guardian

    function setParams(PoolParams calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _accrue();
        _setParams(p);
    }

    function setDelegate(address next) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!underwriting.isActiveDelegate(next)) revert Unauthorized();
        emit DelegateChanged(delegate, next);
        delegate = next;
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ================================================================== delegate

    function approveBorrower(address borrower, uint256 limit) external onlyDelegate {
        if (!compliance.canBorrow(borrower)) revert NotCompliant(borrower);
        approvedBorrower[borrower] = true;
        borrowerLimit[borrower] = limit;
        emit BorrowerApproved(borrower, limit);
    }

    function revokeBorrower(address borrower) external onlyDelegate {
        approvedBorrower[borrower] = false;
        borrowerLimit[borrower] = 0;
        emit BorrowerRevoked(borrower);
    }

    /// @notice Delegate approves a submitted invoice and the pool advances `advance` to the borrower.
    /// @param feeBps Flat financing fee on the advance for the invoice's life (<= params.maxFeeBps).
    /// @param attestation Hash of the off-chain underwriting package (debtor confirmation, docs review).
    function fundInvoice(uint256 tokenId, uint256 advance, uint16 feeBps, bytes32 attestation)
        external
        onlyDelegate
        whenActive
        nonReentrant
    {
        Loan storage loan = _loans[tokenId];
        if (loan.status != LoanStatus.Submitted) revert BadLoanStatus(loan.status);
        (address borrower, uint256 faceValue, uint64 dueDate, InvoiceStatus invStatus, bool financed) =
            invoiceNFT.terms(tokenId);
        if (invStatus != InvoiceStatus.Submitted || financed || borrower != loan.borrower) revert BadInvoice();
        if (dueDate <= block.timestamp) revert BadInvoice();
        PoolParams memory p = _params;
        if (dueDate > block.timestamp + p.maxTenor) revert TenorTooLong();
        if (advance == 0) revert ZeroAmount();
        if (advance > (faceValue * p.advanceRateBps) / BPS) revert AdvanceTooHigh();
        if (feeBps > p.maxFeeBps) revert FeeTooHigh();
        if (!approvedBorrower[borrower]) revert BorrowerNotApproved(borrower);
        if (!compliance.canBorrow(borrower)) revert NotCompliant(borrower);

        _accrue();
        if (advance > cash) revert InsufficientCash();
        if (_activeLoans.length() >= p.maxActiveLoans) revert TooManyLoans();
        uint256 exposure = borrowerOutstanding[borrower] + advance;
        if (exposure > borrowerLimit[borrower]) revert LimitExceeded();
        if (exposure * BPS > (seniorAssets + juniorAssets) * p.maxBorrowerConcentrationBps) {
            revert ConcentrationExceeded();
        }
        if (firstLossVault.stake() < _requiredFirstLoss(outstandingPrincipal + advance)) {
            revert InsufficientFirstLoss();
        }

        uint256 fee = (advance * feeBps) / BPS;
        loan.status = LoanStatus.Funded;
        loan.fundedAt = uint64(block.timestamp);
        loan.dueDate = dueDate;
        loan.principal = SafeCast.toUint128(advance);
        loan.principalOwed = SafeCast.toUint128(advance);
        loan.feeOwed = SafeCast.toUint128(fee);
        loan.attestation = attestation;
        outstandingPrincipal += advance;
        cash -= advance;
        borrowerOutstanding[borrower] = exposure;
        if (!_activeLoans.add(tokenId)) revert BadLoanStatus(LoanStatus.Funded);

        emit InvoiceFunded(tokenId, borrower, advance, fee, dueDate, attestation);
        invoiceNFT.markFinanced(tokenId); // reverts if this invoice was ever financed before
        asset.safeTransfer(borrower, advance);
    }

    function rejectInvoice(uint256 tokenId) external onlyDelegate nonReentrant {
        _release(tokenId, true);
    }

    // ================================================================== borrower

    function submitInvoice(uint256 tokenId) external whenActive nonReentrant {
        if (!approvedBorrower[msg.sender]) revert BorrowerNotApproved(msg.sender);
        if (!compliance.canBorrow(msg.sender)) revert NotCompliant(msg.sender);
        (address borrower, uint256 faceValue, uint64 dueDate, InvoiceStatus invStatus, bool financed) =
            invoiceNFT.terms(tokenId);
        if (
            borrower != msg.sender || faceValue < 1 || invStatus != InvoiceStatus.Minted || financed
                || dueDate <= block.timestamp
        ) {
            revert BadInvoice();
        }
        Loan storage loan = _loans[tokenId];
        if (loan.status != LoanStatus.None) revert BadLoanStatus(loan.status);
        loan.borrower = msg.sender;
        loan.status = LoanStatus.Submitted;
        emit InvoiceSubmitted(tokenId, msg.sender);
        invoiceNFT.transferFrom(msg.sender, address(this), tokenId);
        invoiceNFT.markSubmitted(tokenId);
    }

    function withdrawSubmission(uint256 tokenId) external nonReentrant {
        if (_loans[tokenId].borrower != msg.sender) revert Unauthorized();
        _release(tokenId, false);
    }

    /// @notice Repay a funded loan. Anyone (e.g. the invoice debtor) may pay. Fees are settled before
    ///         principal; the fee portion runs through the income waterfall. Allowed while paused so
    ///         borrowers are never pushed into late fees by an emergency pause.
    function repay(uint256 tokenId, uint256 amount) external nonReentrant returns (uint256 paid) {
        Loan storage loan = _loans[tokenId];
        LoanStatus status = loan.status;
        if (status != LoanStatus.Funded && status != LoanStatus.Late) revert BadLoanStatus(status);
        if (amount == 0) revert ZeroAmount();
        _accrue();
        _chargeLateFee(tokenId, loan);

        uint256 feeOwed = loan.feeOwed;
        uint256 principalOwed = loan.principalOwed;
        paid = Math.min(amount, feeOwed + principalOwed);
        uint256 feePart = Math.min(paid, feeOwed);
        uint256 principalPart = paid - feePart;

        loan.feeOwed = SafeCast.toUint128(feeOwed - feePart);
        loan.principalOwed = SafeCast.toUint128(principalOwed - principalPart);
        outstandingPrincipal -= principalPart;
        cash += principalPart;
        borrowerOutstanding[loan.borrower] -= principalPart;
        emit Repayment(tokenId, msg.sender, feePart, principalPart);

        bool closed = loan.feeOwed == 0 && loan.principalOwed == 0;
        if (closed) {
            loan.status = LoanStatus.Repaid;
            if (!_activeLoans.remove(tokenId)) revert BadLoanStatus(status);
            emit LoanRepaid(tokenId);
        }

        (uint256 toProtocol, uint256 toDelegate) = _applyIncome(feePart);
        asset.safeTransferFrom(msg.sender, address(this), paid);
        _payIncome(toProtocol, toDelegate);
        if (closed) {
            invoiceNFT.markRepaid(tokenId);
            invoiceNFT.transferFrom(address(this), loan.borrower, tokenId);
        }
    }

    /// @notice Pay recovery proceeds (collections, legal recovery, backstop liquidation) for a defaulted loan.
    function recover(uint256 tokenId, uint256 amount) external nonReentrant {
        Loan storage loan = _loans[tokenId];
        if (loan.status != LoanStatus.Defaulted) revert BadLoanStatus(loan.status);
        if (amount == 0) revert ZeroAmount();
        _accrue();
        Waterfall.RecoverySplit memory s = Waterfall.allocateRecovery(
            amount, seniorWritedown, seniorInterestOwed, juniorWritedown, firstLossWritedown
        );
        seniorWritedown -= s.senior;
        seniorInterestOwed -= s.seniorInterest;
        juniorWritedown -= s.junior;
        firstLossWritedown -= s.firstLoss;
        seniorAssets += s.senior + s.seniorInterest;
        juniorAssets += s.junior;
        cash += s.senior + s.seniorInterest + s.junior;
        loan.recovered += SafeCast.toUint128(amount);
        lossStats.recovered += SafeCast.toUint128(amount);
        emit Recovery(tokenId, msg.sender, amount, s.senior + s.seniorInterest, s.junior, s.firstLoss, s.excess);
        (uint256 toProtocol, uint256 toDelegate) = _applyIncome(s.excess);

        asset.safeTransferFrom(msg.sender, address(this), amount);
        if (s.firstLoss > 0) {
            asset.safeTransfer(address(firstLossVault), s.firstLoss);
            firstLossVault.notifyDeposit(s.firstLoss);
        }
        _payIncome(toProtocol, toDelegate);
    }

    // ================================================================== DefaultManager

    function markPastDue(uint256 tokenId) external onlyDefaultManager {
        Loan storage loan = _loans[tokenId];
        if (loan.status != LoanStatus.Funded) revert BadLoanStatus(loan.status);
        if (block.timestamp <= loan.dueDate) revert NotPastDue();
        loan.status = LoanStatus.Late;
        emit LoanPastDue(tokenId);
    }

    /// @notice Writes off the outstanding principal of a loan. Loss order: first-loss -> junior -> senior.
    /// @return seniorLoss Amount written off senior NAV (to be reimbursed by the $DRFT backstop, if active).
    function writeOff(uint256 tokenId) external onlyDefaultManager nonReentrant returns (uint256 seniorLoss) {
        Loan storage loan = _loans[tokenId];
        LoanStatus status = loan.status;
        if (status != LoanStatus.Funded && status != LoanStatus.Late) revert BadLoanStatus(status);
        _accrue();
        uint256 loss = loan.principalOwed;
        loan.status = LoanStatus.Defaulted;
        loan.principalOwed = 0;
        loan.feeOwed = 0;
        if (!_activeLoans.remove(tokenId)) revert BadLoanStatus(status);
        outstandingPrincipal -= loss;
        borrowerOutstanding[loan.borrower] -= loss;

        Waterfall.LossSplit memory s =
            Waterfall.allocateLoss(loss, firstLossVault.stake(), juniorAssets, seniorAssets);
        juniorAssets -= s.junior;
        seniorAssets -= s.senior;
        cash += s.firstLoss;
        firstLossWritedown += s.firstLoss;
        juniorWritedown += s.junior;
        seniorWritedown += s.senior;
        LossStats storage ls = lossStats;
        ls.defaults += 1;
        ls.totalWrittenOff += SafeCast.toUint128(loss);
        ls.firstLossAbsorbed += SafeCast.toUint128(s.firstLoss);
        ls.juniorAbsorbed += SafeCast.toUint128(s.junior);
        ls.seniorAbsorbed += SafeCast.toUint128(s.senior);
        emit LoanDefaulted(tokenId, loss, s.firstLoss, s.junior, s.senior);

        if (s.firstLoss > 0) {
            uint256 slashed = firstLossVault.slash(s.firstLoss);
            if (slashed != s.firstLoss) revert InsufficientFirstLoss();
        }
        invoiceNFT.markDefaulted(tokenId);
        return s.senior;
    }

    // ================================================================== tranche / redemption hooks

    function recordDeposit(bool senior, address caller, address receiver, uint256 assets)
        external
        whenActive
    {
        if (msg.sender != address(senior ? seniorTranche : juniorTranche)) revert Unauthorized();
        if (compliance.isBlocked(caller)) revert NotCompliant(caller);
        if (assets == 0) revert ZeroAmount();
        if (assets > maxDeposit(senior, receiver)) revert DepositTooLarge();
        _accrue();
        if (senior) seniorAssets += assets;
        else juniorAssets += assets;
        cash += assets;
        emit Deposited(senior, caller, receiver, assets);
    }

    function executeRedemption(bool senior, uint256 shares) external whenActive returns (uint256 assets) {
        if (msg.sender != epochRedemptions) revert Unauthorized();
        ITranche tranche = senior ? seniorTranche : juniorTranche;
        assets = tranche.convertToAssets(shares);
        if (assets > redeemableAssets(senior)) revert InsufficientCash();
        _accrue();
        if (senior) seniorAssets -= assets;
        else juniorAssets -= assets;
        cash -= assets;
        emit Redeemed(senior, shares, assets);
        tranche.burnFrom(msg.sender, shares);
        asset.safeTransfer(msg.sender, assets);
    }

    // ================================================================== views

    function params() external view returns (PoolParams memory) {
        return _params;
    }

    function maxSeniorRatioBps() external view returns (uint256) {
        return _params.maxSeniorRatioBps;
    }

    function getLoan(uint256 tokenId) external view returns (Loan memory) {
        return _loans[tokenId];
    }

    function activeLoanCount() external view returns (uint256) {
        return _activeLoans.length();
    }

    function activeLoans(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 len = _activeLoans.length();
        if (offset >= len) return new uint256[](0);
        uint256 end = Math.min(len, offset + limit);
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            ids[i - offset] = _activeLoans.at(i);
        }
    }

    function isActive() public view returns (bool) {
        return !paused() && !factory.paused();
    }

    /// @notice True while any active loan is past its due date. Blocks deposits, epoch redemptions and
    ///         first-loss withdrawals so nobody can enter or exit at a stale NAV ahead of a known default.
    /// @dev Bounded by params.maxActiveLoans (<= 250).
    function isImpaired() public view returns (bool) {
        uint256 len = _activeLoans.length();
        for (uint256 i; i < len; ++i) {
            if (_loans[_activeLoans.at(i)].dueDate < block.timestamp) return true;
        }
        return false;
    }

    function trancheAssets(bool senior) external view returns (uint256) {
        return senior ? seniorAssets : juniorAssets;
    }

    function requiredFirstLoss() external view returns (uint256) {
        return _requiredFirstLoss(outstandingPrincipal);
    }

    function canHoldShares(address account) external view returns (bool) {
        return compliance.canLend(account);
    }

    function maxDeposit(bool senior, address receiver) public view returns (uint256) {
        if (!isActive() || !compliance.canLend(receiver) || isImpaired()) return 0;
        uint256 s = seniorAssets;
        uint256 j = juniorAssets;
        // A wiped-out tranche with live shares must be recapitalised by governance, not by new depositors.
        ITranche tranche = senior ? seniorTranche : juniorTranche;
        if ((senior ? s : j) == 0 && tranche.totalSupply() != 0) return 0;
        PoolParams storage p = _params;
        uint256 total = s + j;
        uint256 room = p.poolCap > total ? p.poolCap - total : 0;
        if (senior) {
            // (s + x) <= r * (s + x + j)  =>  x <= r*j/(BPS - r) - s
            uint256 r = p.maxSeniorRatioBps;
            uint256 seniorMax = (r * j) / (BPS - r);
            room = Math.min(room, seniorMax > s ? seniorMax - s : 0);
        }
        return room;
    }

    /// @notice Assets that epoch redemptions may take from `senior`/junior right now. Senior has first call
    ///         on cash; junior may not redeem below the subordination required by maxSeniorRatioBps.
    function redeemableAssets(bool senior) public view returns (uint256) {
        if (senior) return Math.min(cash, seniorAssets);
        uint256 r = _params.maxSeniorRatioBps;
        uint256 s = seniorAssets;
        uint256 minJunior = 0;
        if (s > 0) minJunior = r > 0 ? Math.mulDiv(s, BPS - r, r, Math.Rounding.Ceil) : type(uint256).max;
        uint256 j = juniorAssets;
        uint256 free = j > minJunior ? j - minJunior : 0;
        return Math.min(cash, free);
    }

    /// @notice Earliest timestamp at which anyone may trigger a default on `tokenId`.
    function defaultableAt(uint256 tokenId) external view returns (uint256) {
        Loan storage loan = _loans[tokenId];
        if (loan.status != LoanStatus.Funded && loan.status != LoanStatus.Late) return type(uint256).max;
        return uint256(loan.dueDate) + _params.gracePeriod + _params.defaultWindow;
    }

    // ================================================================== internals

    function _release(uint256 tokenId, bool byDelegate) private {
        Loan storage loan = _loans[tokenId];
        if (loan.status != LoanStatus.Submitted) revert BadLoanStatus(loan.status);
        address borrower = loan.borrower;
        delete _loans[tokenId];
        emit InvoiceReleased(tokenId, borrower, byDelegate);
        invoiceNFT.markReleased(tokenId);
        invoiceNFT.transferFrom(address(this), borrower, tokenId);
    }

    function _chargeLateFee(uint256 tokenId, Loan storage loan) private {
        if (loan.lateFeeCharged || block.timestamp <= uint256(loan.dueDate) + _params.gracePeriod) return;
        uint256 lateFee = (uint256(loan.principalOwed) * _params.lateFeeBps) / BPS;
        loan.lateFeeCharged = true;
        loan.feeOwed += SafeCast.toUint128(lateFee);
        emit LateFeeCharged(tokenId, lateFee);
    }

    /// @dev Senior/junior coupons accrue only on their pro-rata share of deployed capital.
    function _accrual() private view returns (uint256 seniorDelta, uint256 juniorDelta) {
        uint256 last = lastAccrual;
        uint256 total = seniorAssets + juniorAssets;
        uint256 out = outstandingPrincipal;
        if (block.timestamp <= last || total < 1 || out < 1) return (0, 0);
        uint256 dt = block.timestamp - last;
        uint256 seniorBase = Math.mulDiv(out, seniorAssets, total);
        uint256 juniorBase = out - seniorBase;
        seniorDelta = Math.mulDiv(seniorBase, uint256(_params.seniorRateBps) * dt, BPS * YEAR);
        juniorDelta = Math.mulDiv(juniorBase, uint256(_params.juniorHurdleBps) * dt, BPS * YEAR);
    }

    function _accrue() private {
        (uint256 ds, uint256 dj) = _accrual();
        lastAccrual = uint64(block.timestamp);
        if (ds > 0 || dj > 0) {
            seniorInterestOwed += ds;
            juniorInterestOwed += dj;
            emit InterestAccrued(seniorInterestOwed, juniorInterestOwed);
        }
    }

    /// @dev Income waterfall (effects only): senior interest -> junior hurdle -> protocol/delegate fee on
    ///      excess -> junior. Junior never receives anything unless senior interest owed is fully paid.
    function _applyIncome(uint256 amount) private returns (uint256 toProtocol, uint256 toDelegate) {
        if (amount < 1) return (0, 0);
        Waterfall.IncomeSplit memory s = Waterfall.distributeIncome(
            amount, seniorInterestOwed, juniorInterestOwed, _params.protocolFeeBps, _params.delegateFeeBps
        );
        toProtocol = s.protocol;
        toDelegate = s.delegate;
        uint256 juniorResidual = s.juniorResidual;
        // With no junior holders the residual would be stranded in an empty tranche: send it to the protocol.
        if (juniorTranche.totalSupply() == 0) {
            toProtocol += juniorResidual;
            juniorResidual = 0;
        }
        uint256 toJunior = s.juniorHurdle + juniorResidual;
        seniorInterestOwed -= s.senior;
        juniorInterestOwed -= s.juniorHurdle;
        seniorAssets += s.senior;
        juniorAssets += toJunior;
        cash += s.senior + toJunior;
        emit IncomeDistributed(amount, s.senior, s.juniorHurdle, juniorResidual, toProtocol, toDelegate);
    }

    /// @dev Income waterfall (interactions): pay protocol fee and delegate fee (credited to first-loss stake).
    function _payIncome(uint256 toProtocol, uint256 toDelegate) private {
        if (toProtocol > 0) asset.safeTransfer(feeCollector, toProtocol);
        if (toDelegate > 0) {
            asset.safeTransfer(address(firstLossVault), toDelegate);
            firstLossVault.notifyDeposit(toDelegate);
        }
    }

    function _requiredFirstLoss(uint256 outstanding) private view returns (uint256) {
        return Math.max(_params.minFirstLossAmount, (outstanding * _params.minFirstLossBps) / BPS);
    }

    function _setParams(PoolParams memory p) private {
        if (!PoolParamsLib.isValid(p)) revert InvalidParams();
        _params = p;
        emit ParamsUpdated(p);
    }
}
