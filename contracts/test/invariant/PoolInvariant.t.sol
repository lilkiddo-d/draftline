// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {CreditPool} from "../../src/pool/CreditPool.sol";
import {Tranche} from "../../src/pool/Tranche.sol";
import {FirstLossVault} from "../../src/pool/FirstLossVault.sol";
import {EpochRedemptions} from "../../src/pool/EpochRedemptions.sol";
import {InvoiceNFT} from "../../src/pool/InvoiceNFT.sol";
import {DefaultManager} from "../../src/pool/DefaultManager.sol";
import {LoanStatus} from "../../src/libraries/Types.sol";

/// @notice Drives a pool through random deposits, originations, repayments, defaults, recoveries,
///         redemptions, time jumps and double-financing attempts, recording ordering violations as ghosts.
contract PoolHandler is Test {
    uint256 constant USD = 1e6;

    CreditPool pool;
    Tranche senior;
    Tranche junior;
    FirstLossVault flv;
    EpochRedemptions epochs;
    InvoiceNFT nft;
    DefaultManager dm;
    MockERC20 usdg;
    address delegate;
    address borrower;
    address[3] lenders;

    uint256[] public loanIds;
    uint256 nonce;

    // ghosts
    uint256 public ghost_doubleFinance;
    uint256 public ghost_lossOrderViolations;
    uint256 public ghost_juniorBeforeSenior;
    uint256 public ghost_defaults;
    uint256 public ghost_repays;
    mapping(uint256 => uint256) public fundCount;

    constructor(
        CreditPool pool_,
        InvoiceNFT nft_,
        DefaultManager dm_,
        MockERC20 usdg_,
        address delegate_,
        address borrower_
    ) {
        pool = pool_;
        senior = Tranche(address(pool_.seniorTranche()));
        junior = Tranche(address(pool_.juniorTranche()));
        flv = FirstLossVault(address(pool_.firstLossVault()));
        epochs = EpochRedemptions(pool_.epochRedemptions());
        nft = nft_;
        dm = dm_;
        usdg = usdg_;
        delegate = delegate_;
        borrower = borrower_;
        lenders = [makeAddr("l1"), makeAddr("l2"), makeAddr("l3")];
    }

    function loanCount() external view returns (uint256) {
        return loanIds.length;
    }

    // ------------------------------------------------------------------ actions

    function deposit(uint256 who, bool isSenior, uint256 amount) external {
        uint256 max = pool.maxDeposit(isSenior, lenders[who % 3]);
        if (max == 0) return;
        amount = bound(amount, 1, max > 2_000_000 * USD ? 2_000_000 * USD : max);
        address l = lenders[who % 3];
        Tranche t = isSenior ? senior : junior;
        usdg.mint(l, amount);
        vm.startPrank(l);
        usdg.approve(address(t), amount);
        t.deposit(amount, l);
        vm.stopPrank();
    }

    function originate(uint256 face, uint256 advanceBps, uint256 feeBps, uint256 tenor) external {
        face = bound(face, 1_000 * USD, 500_000 * USD);
        uint256 advance = (face * bound(advanceBps, 1, 8_000)) / 10_000;
        if (advance == 0) return;
        tenor = bound(tenor, 1 days, 180 days);
        nonce++;
        vm.prank(borrower);
        uint256 id = nft.mint(
            uint128(face),
            uint64(block.timestamp + tenor),
            keccak256(abi.encode("d", nonce)),
            keccak256(abi.encode("n", nonce)),
            "cid"
        );
        vm.startPrank(borrower);
        nft.approve(address(pool), id);
        try pool.submitInvoice(id) {} catch {
            vm.stopPrank();
            return;
        }
        vm.stopPrank();
        vm.prank(delegate);
        try pool.fundInvoice(id, advance, uint16(bound(feeBps, 0, 1_000)), bytes32(nonce)) {
            fundCount[id]++;
            loanIds.push(id);
        } catch {
            vm.prank(delegate);
            pool.rejectInvoice(id);
        }
    }

    /// @dev Tries every route to finance an already-financed invoice a second time.
    function refinance(uint256 idx) external {
        if (loanIds.length == 0) return;
        uint256 id = loanIds[idx % loanIds.length];
        address holder = nft.ownerOf(id);
        if (holder == borrower) {
            vm.startPrank(borrower);
            nft.approve(address(pool), id);
            try pool.submitInvoice(id) {
                vm.stopPrank();
                vm.prank(delegate);
                try pool.fundInvoice(id, 1 * USD, 0, 0) {
                    ghost_doubleFinance++;
                } catch {}
                return;
            } catch {}
            vm.stopPrank();
        }
        vm.prank(delegate);
        try pool.fundInvoice(id, 1 * USD, 0, 0) {
            ghost_doubleFinance++;
        } catch {}
    }

    function repay(uint256 idx, uint256 amount) external {
        if (loanIds.length == 0) return;
        uint256 id = loanIds[idx % loanIds.length];
        LoanStatus st = pool.getLoan(id).status;
        if (st != LoanStatus.Funded && st != LoanStatus.Late) return;
        amount = bound(amount, 1, 600_000 * USD);
        uint256 jBefore = pool.juniorAssets();
        usdg.mint(address(this), amount);
        usdg.approve(address(pool), amount);
        pool.repay(id, amount);
        ghost_repays++;
        if (pool.juniorAssets() > jBefore && pool.seniorInterestOwed() != 0) ghost_juniorBeforeSenior++;
    }

    function recover(uint256 idx, uint256 amount) external {
        if (loanIds.length == 0) return;
        uint256 id = loanIds[idx % loanIds.length];
        if (pool.getLoan(id).status != LoanStatus.Defaulted) return;
        amount = bound(amount, 1, 600_000 * USD);
        uint256 jBefore = pool.juniorAssets();
        usdg.mint(address(this), amount);
        usdg.approve(address(pool), amount);
        pool.recover(id, amount);
        if (pool.juniorAssets() > jBefore && pool.seniorInterestOwed() != 0) ghost_juniorBeforeSenior++;
    }

    function triggerDefault(uint256 idx, bool early) external {
        if (loanIds.length == 0) return;
        uint256 id = loanIds[idx % loanIds.length];
        LoanStatus st = pool.getLoan(id).status;
        if (st != LoanStatus.Funded && st != LoanStatus.Late) return;
        uint256 fl = flv.stake();
        uint256 j = pool.juniorAssets();
        uint256 s = pool.seniorAssets();
        if (early) {
            vm.prank(delegate);
            dm.declareDefault(address(pool), id);
        } else {
            uint256 at = pool.defaultableAt(id);
            if (block.timestamp < at) vm.warp(at);
            dm.triggerDefault(address(pool), id);
        }
        ghost_defaults++;
        uint256 jLoss = j - pool.juniorAssets();
        uint256 sLoss = s - pool.seniorAssets();
        if (jLoss > 0 && flv.stake() != 0) ghost_lossOrderViolations++;
        if (sLoss > 0 && pool.juniorAssets() != 0) ghost_lossOrderViolations++;
        if (fl < flv.stake()) ghost_lossOrderViolations++;
    }

    function markPastDue(uint256 idx) external {
        if (loanIds.length == 0) return;
        uint256 id = loanIds[idx % loanIds.length];
        try dm.markPastDue(address(pool), id) {} catch {}
    }

    function requestRedeem(uint256 who, bool isSenior, uint256 frac) external {
        address l = lenders[who % 3];
        Tranche t = isSenior ? senior : junior;
        uint256 bal = t.balanceOf(l);
        if (bal == 0) return;
        uint256 shares = (bal * bound(frac, 1, 100)) / 100;
        if (shares == 0) return;
        vm.startPrank(l);
        t.approve(address(epochs), shares);
        try epochs.requestRedeem(isSenior, shares) {} catch {}
        vm.stopPrank();
    }

    function closeEpoch() external {
        uint256 endsAt = epochs.epochEndsAt();
        if (block.timestamp < endsAt) vm.warp(endsAt);
        try epochs.closeEpoch() {} catch {}
    }

    function claim(uint256 who, bool isSenior) external {
        vm.prank(lenders[who % 3]);
        try epochs.claim(isSenior) {} catch {}
    }

    function topUpFirstLoss(uint256 amount) external {
        amount = bound(amount, 1, 200_000 * USD);
        usdg.mint(delegate, amount);
        vm.startPrank(delegate);
        usdg.approve(address(flv), amount);
        flv.deposit(amount);
        vm.stopPrank();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 20 days));
    }
}

contract PoolInvariantTest is BaseTest {
    PoolHandler handler;

    function setUp() public override {
        super.setUp();
        _seedLiquidity();
        vm.prank(delegate);
        pool.approveBorrower(borrower, type(uint128).max);
        handler = new PoolHandler(pool, d.invoiceNFT, d.defaultManager, usdg, delegate, borrower);
        targetContract(address(handler));
    }

    function afterInvariant() public {
        emit log_named_uint("loans", handler.loanCount());
        emit log_named_uint("repays", handler.ghost_repays());
        emit log_named_uint("defaults", handler.ghost_defaults());
    }

    /// @dev Book-value identity: tranche NAV always equals idle cash plus outstanding principal.
    function invariant_navIdentity() public view {
        assertEq(pool.seniorAssets() + pool.juniorAssets(), pool.cash() + pool.outstandingPrincipal());
    }

    /// @dev Internal accounting is always fully backed by real tokens.
    function invariant_solvency() public view {
        assertGe(usdg.balanceOf(address(pool)), pool.cash());
        assertGe(usdg.balanceOf(address(flv)), flv.stake());
    }

    /// @dev Losses always hit first-loss, then junior, then senior.
    function invariant_lossOrder() public view {
        assertEq(handler.ghost_lossOrderViolations(), 0);
    }

    /// @dev The waterfall never pays junior while senior interest is in arrears.
    function invariant_juniorNeverBeforeSenior() public view {
        assertEq(handler.ghost_juniorBeforeSenior(), 0);
    }

    /// @dev One invoice can be financed only once.
    function invariant_financedOnce() public view {
        assertEq(handler.ghost_doubleFinance(), 0);
        uint256 n = handler.loanCount();
        for (uint256 i; i < n; ++i) {
            assertLe(handler.fundCount(handler.loanIds(i)), 1);
        }
    }

    /// @dev Write-down buckets never exceed what was actually written off.
    function invariant_writedownsBounded() public view {
        (, uint128 total,,,, uint128 recovered) = pool.lossStats();
        assertLe(pool.seniorWritedown() + pool.juniorWritedown() + pool.firstLossWritedown(), uint256(total));
        recovered; // recovered can exceed write-downs (excess is income)
    }

    /// @dev Queued redemption shares are always held by the escrow.
    function invariant_escrowBacked() public view {
        uint256 e = epochs.currentEpoch();
        assertGe(senior.balanceOf(address(epochs)), epochs.epochData(e, true).requested);
        assertGe(junior.balanceOf(address(epochs)), epochs.epochData(e, false).requested);
    }
}
