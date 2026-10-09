// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {CreditPool} from "../../src/pool/CreditPool.sol";
import {InvoiceNFT} from "../../src/pool/InvoiceNFT.sol";
import {DefaultManager} from "../../src/pool/DefaultManager.sol";
import {LoanStatus, InvoiceStatus, PoolParams} from "../../src/libraries/Types.sol";

contract CreditPoolTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _seedLiquidity();
    }

    // ================================================================ deposits

    function test_deposit_booksAssetsAndCash() public view {
        assertEq(pool.seniorAssets(), 800_000 * USD);
        assertEq(pool.juniorAssets(), 200_000 * USD);
        assertEq(pool.cash(), 1_000_000 * USD);
        assertEq(usdg.balanceOf(address(pool)), 1_000_000 * USD);
        assertEq(senior.totalAssets(), 800_000 * USD);
        assertEq(senior.balanceOf(alice), 800_000 * USD * 1e6);
        _assertAccounting();
    }

    function test_deposit_seniorCappedBySubordination() public {
        assertEq(pool.maxDeposit(true, carol), 0, "senior at cap");
        _deposit(bob, false, 50_000 * USD);
        // j = 250k, r = 80% => senior max = 4 * 250k = 1M => room 200k
        assertEq(pool.maxDeposit(true, carol), 200_000 * USD);
        usdg.mint(carol, 200_001 * USD);
        vm.startPrank(carol);
        usdg.approve(address(senior), type(uint256).max);
        vm.expectRevert();
        senior.deposit(200_001 * USD, carol);
        senior.deposit(200_000 * USD, carol);
        vm.stopPrank();
    }

    function test_deposit_poolCap() public {
        PoolParams memory p = defaultParams();
        p.poolCap = uint128(1_100_000 * USD);
        vm.prank(timelock);
        pool.setParams(p);
        assertEq(pool.maxDeposit(false, carol), 100_000 * USD);
        assertEq(junior.maxMint(carol), junior.convertToShares(100_000 * USD));
    }

    function test_deposit_blockedWhenLenderKycRequired() public {
        vm.prank(timelock);
        d.compliance.setRequirements(true, true, true);
        assertEq(pool.maxDeposit(false, carol), 0);
        vm.prank(officer);
        d.compliance.setKyc(carol, FAR);
        assertGt(pool.maxDeposit(false, carol), 0);
    }

    function test_deposit_blockedCallerReverts() public {
        vm.prank(officer);
        d.compliance.setBlocked(carol, true);
        usdg.mint(carol, 1_000 * USD);
        vm.startPrank(carol);
        usdg.approve(address(junior), 1_000 * USD);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.NotCompliant.selector, carol));
        junior.deposit(1_000 * USD, bob);
        vm.stopPrank();
    }

    function test_recordDeposit_onlyTranche() public {
        vm.expectRevert(CreditPool.Unauthorized.selector);
        pool.recordDeposit(true, alice, alice, 1);
    }

    function test_recordDeposit_zeroAndTooLarge() public {
        vm.startPrank(address(junior));
        vm.expectRevert(CreditPool.ZeroAmount.selector);
        pool.recordDeposit(false, carol, carol, 0);
        vm.stopPrank();
        vm.prank(address(senior));
        vm.expectRevert(CreditPool.DepositTooLarge.selector);
        pool.recordDeposit(true, carol, carol, 1);
    }

    function test_deposit_blockedWhilePaused() public {
        vm.prank(guardian);
        pool.pause();
        assertEq(pool.maxDeposit(false, carol), 0);
        assertFalse(pool.isActive());
        vm.prank(timelock);
        pool.unpause();
        assertTrue(pool.isActive());

        vm.prank(guardian);
        d.factory.pause();
        assertFalse(pool.isActive());
    }

    function test_pause_roles() public {
        vm.expectRevert(CreditPool.Unauthorized.selector);
        pool.pause();
        vm.prank(guardian);
        pool.pause();
        vm.prank(guardian);
        vm.expectRevert(CreditPool.Unauthorized.selector);
        pool.unpause();
    }

    // ================================================================ borrower onboarding

    function test_approveBorrower_requiresKyc() public {
        vm.prank(delegate);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.NotCompliant.selector, carol));
        pool.approveBorrower(carol, 1);
    }

    function test_revokeBorrower() public {
        vm.prank(delegate);
        pool.revokeBorrower(borrower);
        assertFalse(pool.approvedBorrower(borrower));
        uint256 id = _mintInvoice(borrower, 100_000 * USD, uint64(block.timestamp + 30 days));
        vm.startPrank(borrower);
        d.invoiceNFT.approve(address(pool), id);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.BorrowerNotApproved.selector, borrower));
        pool.submitInvoice(id);
        vm.stopPrank();
    }

    function test_onlyDelegate() public {
        vm.prank(carol);
        vm.expectRevert(CreditPool.Unauthorized.selector);
        pool.approveBorrower(borrower, 1);
        // revoked delegate loses powers immediately
        vm.prank(guardian);
        d.underwriting.revokeDelegate(delegate);
        vm.prank(delegate);
        vm.expectRevert(CreditPool.Unauthorized.selector);
        pool.approveBorrower(borrower, 1);
    }

    // ================================================================ submit / reject / withdraw

    function test_submit_escrowsNft() public {
        uint256 id = _mintInvoice(borrower, 100_000 * USD, uint64(block.timestamp + 30 days));
        _submit(borrower, id);
        assertEq(d.invoiceNFT.ownerOf(id), address(pool));
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.Submitted));
        (,,, InvoiceStatus st,) = d.invoiceNFT.terms(id);
        assertEq(uint8(st), uint8(InvoiceStatus.Submitted));
    }

    function test_submit_rejectsForeignOrStaleInvoice() public {
        vm.prank(delegate);
        pool.approveBorrower(borrower2, 100_000 * USD);
        uint256 id = _mintInvoice(borrower, 100_000 * USD, uint64(block.timestamp + 30 days));
        vm.prank(borrower2);
        vm.expectRevert(CreditPool.BadInvoice.selector);
        pool.submitInvoice(id);

        uint256 id2 = _mintInvoice(borrower, 100_000 * USD, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
        vm.prank(borrower);
        vm.expectRevert(CreditPool.BadInvoice.selector);
        pool.submitInvoice(id2);
    }

    function test_submit_borrowerLosesKyc() public {
        uint256 id = _mintInvoice(borrower, 100_000 * USD, uint64(block.timestamp + 30 days));
        vm.prank(officer);
        d.compliance.setKyc(borrower, 0);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.NotCompliant.selector, borrower));
        pool.submitInvoice(id);
    }

    function test_reject_returnsNft_andCanResubmit() public {
        uint256 id = _mintInvoice(borrower, 100_000 * USD, uint64(block.timestamp + 30 days));
        _submit(borrower, id);
        vm.prank(delegate);
        pool.rejectInvoice(id);
        assertEq(d.invoiceNFT.ownerOf(id), borrower);
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.None));
        _submit(borrower, id);
        _fund(id, 80_000 * USD, 300);
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.Funded));
    }

    function test_withdrawSubmission() public {
        uint256 id = _mintInvoice(borrower, 100_000 * USD, uint64(block.timestamp + 30 days));
        _submit(borrower, id);
        vm.prank(carol);
        vm.expectRevert(CreditPool.Unauthorized.selector);
        pool.withdrawSubmission(id);
        vm.prank(borrower);
        pool.withdrawSubmission(id);
        assertEq(d.invoiceNFT.ownerOf(id), borrower);
    }

    function test_cannotRejectFunded() public {
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        vm.prank(delegate);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.BadLoanStatus.selector, LoanStatus.Funded));
        pool.rejectInvoice(id);
    }

    // ================================================================ funding

    function test_fund_paysAdvance() public {
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 60 days);
        assertEq(usdg.balanceOf(borrower), 80_000 * USD);
        assertEq(pool.outstandingPrincipal(), 80_000 * USD);
        assertEq(pool.cash(), 920_000 * USD);
        assertEq(pool.borrowerOutstanding(borrower), 80_000 * USD);
        CreditPool.Loan memory l = pool.getLoan(id);
        assertEq(l.feeOwed, 2_400 * USD);
        assertEq(l.principalOwed, 80_000 * USD);
        (,,, InvoiceStatus st, bool financed) = d.invoiceNFT.terms(id);
        assertTrue(financed);
        assertEq(uint8(st), uint8(InvoiceStatus.Financed));
        assertEq(pool.activeLoanCount(), 1);
        _assertAccounting();
    }

    function test_fund_guards() public {
        uint64 due = uint64(block.timestamp + 30 days);
        uint256 id = _mintInvoice(borrower, 100_000 * USD, due);
        // not submitted
        vm.prank(delegate);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.BadLoanStatus.selector, LoanStatus.None));
        pool.fundInvoice(id, 1, 0, 0);
        _submit(borrower, id);

        vm.startPrank(delegate);
        vm.expectRevert(CreditPool.AdvanceTooHigh.selector);
        pool.fundInvoice(id, 80_000 * USD + 1, 100, 0);
        vm.expectRevert(CreditPool.ZeroAmount.selector);
        pool.fundInvoice(id, 0, 100, 0);
        vm.expectRevert(CreditPool.FeeTooHigh.selector);
        pool.fundInvoice(id, 1_000 * USD, 1_001, 0);
        vm.stopPrank();

        // tenor
        uint256 longId = _mintInvoice(borrower, 100_000 * USD, uint64(block.timestamp + 181 days));
        _submit(borrower, longId);
        vm.prank(delegate);
        vm.expectRevert(CreditPool.TenorTooLong.selector);
        pool.fundInvoice(longId, 1_000 * USD, 100, 0);

        // due date passed while waiting
        vm.warp(due + 1);
        vm.prank(delegate);
        vm.expectRevert(CreditPool.BadInvoice.selector);
        pool.fundInvoice(id, 1_000 * USD, 100, 0);
    }

    function test_fund_borrowerChecks() public {
        uint256 id = _mintInvoice(borrower, 100_000 * USD, uint64(block.timestamp + 30 days));
        _submit(borrower, id);
        vm.prank(delegate);
        pool.revokeBorrower(borrower);
        vm.prank(delegate);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.BorrowerNotApproved.selector, borrower));
        pool.fundInvoice(id, 1_000 * USD, 100, 0);

        vm.prank(delegate);
        pool.approveBorrower(borrower, 1_000 * USD);
        vm.prank(officer);
        d.compliance.setBlocked(borrower, true);
        vm.prank(delegate);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.NotCompliant.selector, borrower));
        pool.fundInvoice(id, 1_000 * USD, 100, 0);
    }

    function test_fund_limits() public {
        // borrower limit 600k; concentration 50% of 1M NAV = 500k
        uint256 id = _mintInvoice(borrower, 1_000_000 * USD, uint64(block.timestamp + 30 days));
        _submit(borrower, id);
        vm.prank(delegate);
        vm.expectRevert(CreditPool.ConcentrationExceeded.selector);
        pool.fundInvoice(id, 500_001 * USD, 100, 0);

        vm.prank(delegate);
        pool.approveBorrower(borrower, 100_000 * USD);
        vm.prank(delegate);
        vm.expectRevert(CreditPool.LimitExceeded.selector);
        pool.fundInvoice(id, 100_001 * USD, 100, 0);
    }

    function test_fund_requiresFirstLossCover() public {
        // 50k stake covers 5% of up to 1M outstanding; demand more by raising the bps.
        PoolParams memory p = defaultParams();
        p.minFirstLossBps = 5_000;
        vm.prank(timelock);
        pool.setParams(p);
        uint256 id = _mintInvoice(borrower, 200_000 * USD, uint64(block.timestamp + 30 days));
        _submit(borrower, id);
        vm.prank(delegate);
        vm.expectRevert(CreditPool.InsufficientFirstLoss.selector);
        pool.fundInvoice(id, 100_001 * USD, 100, 0);
        _fund(id, 100_000 * USD, 100);
    }

    function test_fund_insufficientCash_andTooManyLoans() public {
        PoolParams memory p = defaultParams();
        p.maxActiveLoans = 1;
        p.maxBorrowerConcentrationBps = 10_000;
        vm.prank(timelock);
        pool.setParams(p);
        vm.prank(delegate);
        pool.approveBorrower(borrower, 10_000_000 * USD);
        _fundFirstLoss(1_000_000 * USD);
        uint256 id = _mintInvoice(borrower, 5_000_000 * USD, uint64(block.timestamp + 30 days));
        _submit(borrower, id);
        vm.prank(delegate);
        vm.expectRevert(CreditPool.InsufficientCash.selector);
        pool.fundInvoice(id, 1_000_001 * USD, 100, 0);
        _fund(id, 10_000 * USD, 100);
        uint256 id2 = _mintInvoice(borrower, 50_000 * USD, uint64(block.timestamp + 30 days));
        _submit(borrower, id2);
        vm.prank(delegate);
        vm.expectRevert(CreditPool.TooManyLoans.selector);
        pool.fundInvoice(id2, 10_000 * USD, 100, 0);
    }

    function test_fund_whenPausedReverts() public {
        uint256 id = _mintInvoice(borrower, 100_000 * USD, uint64(block.timestamp + 30 days));
        _submit(borrower, id);
        vm.prank(guardian);
        pool.pause();
        vm.prank(delegate);
        vm.expectRevert(CreditPool.PoolInactive.selector);
        pool.fundInvoice(id, 1_000 * USD, 100, 0);
    }

    // ================================================================ repayment & waterfall

    function test_repay_full_waterfall() public {
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 60 days);
        vm.warp(block.timestamp + 30 days);
        (uint256 sOwed, uint256 jOwed) = d.lens.pendingInterest(pool);
        // senior base = 80k * 0.8 = 64k at 8% for 30d; junior base 16k at 12%
        assertApproxEqAbs(sOwed, 64_000 * USD * 800 * 30 / (10_000 * 365), 2);
        assertApproxEqAbs(jOwed, 16_000 * USD * 1_200 * 30 / (10_000 * 365), 2);

        uint256 seniorBefore = pool.seniorAssets();
        uint256 juniorBefore = pool.juniorAssets();
        uint256 owed = d.lens.amountOwed(pool, id);
        assertEq(owed, 82_400 * USD);
        _repay(debtor, id, owed + 5 * USD); // over-payment is capped

        assertEq(usdg.balanceOf(debtor), 5 * USD, "overpayment refunded (never pulled)");
        uint256 fee = 2_400 * USD;
        uint256 excess = fee - sOwed - jOwed;
        uint256 protocolFee = excess * 1_000 / 10_000;
        uint256 delegateFee = excess * 1_000 / 10_000;
        assertEq(pool.seniorAssets() - seniorBefore, sOwed, "senior gets its coupon");
        assertEq(pool.juniorAssets() - juniorBefore, fee - sOwed - protocolFee - delegateFee, "junior residual");
        assertEq(usdg.balanceOf(address(d.feeCollector)), protocolFee);
        assertEq(flv.stake(), 50_000 * USD + delegateFee);
        assertEq(pool.seniorInterestOwed(), 0);
        assertEq(pool.juniorInterestOwed(), 0);
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.Repaid));
        assertEq(d.invoiceNFT.ownerOf(id), borrower, "NFT returned as record");
        assertEq(pool.activeLoanCount(), 0);
        assertEq(pool.outstandingPrincipal(), 0);
        _assertAccounting();
    }

    function test_repay_partial_feesFirst() public {
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 60 days);
        _repay(borrower, id, 3_000 * USD);
        CreditPool.Loan memory l = pool.getLoan(id);
        assertEq(l.feeOwed, 0);
        assertEq(l.principalOwed, 79_400 * USD);
        assertEq(pool.outstandingPrincipal(), 79_400 * USD);
        assertEq(pool.borrowerOutstanding(borrower), 79_400 * USD);
        _repay(borrower, id, 79_400 * USD);
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.Repaid));
        _assertAccounting();
    }

    function test_repay_seniorShortfall_paysNoJunior() public {
        // Tiny fee: income cannot even cover the senior coupon -> junior gets nothing.
        uint256 id = _originate(500_000 * USD, 400_000 * USD, 1, 170 days);
        vm.warp(block.timestamp + 160 days);
        uint256 jBefore = pool.juniorAssets();
        _repay(borrower, id, d.lens.amountOwed(pool, id));
        assertGt(pool.seniorInterestOwed(), 0, "senior still in arrears");
        assertEq(pool.juniorAssets(), jBefore, "junior paid nothing while senior in arrears");
        assertEq(usdg.balanceOf(address(d.feeCollector)), 0);
    }

    function test_repay_lateFee() public {
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        vm.warp(block.timestamp + 30 days + 5 days); // inside grace: no fee
        assertEq(d.lens.amountOwed(pool, id), 82_400 * USD);
        vm.warp(block.timestamp + 1);
        assertEq(d.lens.amountOwed(pool, id), 82_400 * USD + 1_600 * USD);
        usdg.mint(borrower, 1_000 * USD);
        vm.startPrank(borrower);
        usdg.approve(address(pool), 1_000 * USD);
        vm.expectEmit(address(pool));
        emit CreditPool.LateFeeCharged(id, 1_600 * USD);
        pool.repay(id, 1_000 * USD);
        vm.stopPrank();
        assertEq(pool.getLoan(id).feeOwed, 3_000 * USD);
        assertTrue(pool.getLoan(id).lateFeeCharged);
        _repay(borrower, id, 100_000 * USD);
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.Repaid));
        _assertAccounting();
    }

    function test_repay_guards() public {
        vm.expectRevert(abi.encodeWithSelector(CreditPool.BadLoanStatus.selector, LoanStatus.None));
        pool.repay(999, 1);
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        vm.expectRevert(CreditPool.ZeroAmount.selector);
        pool.repay(id, 0);
    }

    function test_repay_worksWhilePaused() public {
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        vm.prank(guardian);
        pool.pause();
        _repay(borrower, id, 82_400 * USD);
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.Repaid));
    }

    function test_income_withNoJuniorHolders_goesToProtocol() public {
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        // Simulate a junior tranche with no holders (no time passes, so no coupon is owed).
        uint256 bobShares = junior.balanceOf(bob);
        vm.prank(address(pool));
        junior.burnFrom(bob, bobShares);
        uint256 jBefore = pool.juniorAssets();
        _repay(borrower, id, 82_400 * USD);
        // fee 2,400: delegate 10% = 240, protocol 10% = 240 + stranded junior residual 1,920
        assertEq(pool.juniorAssets(), jBefore);
        assertEq(usdg.balanceOf(address(d.feeCollector)), 2_160 * USD);
        assertEq(flv.stake(), 50_240 * USD);
    }

    // ================================================================ impairment

    function test_impairment_blocksDepositsUntilResolved() public {
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        assertFalse(pool.isImpaired());
        vm.warp(block.timestamp + 30 days + 1);
        assertTrue(pool.isImpaired());
        assertEq(pool.maxDeposit(false, carol), 0);
        _repay(borrower, id, 82_400 * USD);
        assertFalse(pool.isImpaired());
    }

    function test_activeLoans_pagination() public {
        uint256 a = _originate(10_000 * USD, 8_000 * USD, 100, 30 days);
        uint256 b = _originate(10_000 * USD, 8_000 * USD, 100, 30 days);
        uint256[] memory ids = pool.activeLoans(0, 10);
        assertEq(ids.length, 2);
        assertEq(ids[0], a);
        assertEq(ids[1], b);
        assertEq(pool.activeLoans(1, 10).length, 1);
        assertEq(pool.activeLoans(5, 10).length, 0);
    }

    // ================================================================ admin

    function test_setParams_validation() public {
        PoolParams memory p = defaultParams();
        p.advanceRateBps = 9_600;
        vm.prank(timelock);
        vm.expectRevert(CreditPool.InvalidParams.selector);
        pool.setParams(p);
        vm.expectRevert(CreditPool.Unauthorized.selector);
        pool.setParams(defaultParams());
    }

    function test_setDelegate() public {
        address d2 = makeAddr("delegate2");
        vm.prank(timelock);
        vm.expectRevert(CreditPool.Unauthorized.selector);
        pool.setDelegate(d2);
        vm.prank(officer);
        d.compliance.setKyc(d2, FAR);
        vm.startPrank(timelock);
        d.underwriting.approveDelegate(d2, "");
        pool.setDelegate(d2);
        vm.stopPrank();
        assertEq(pool.delegate(), d2);
    }

    function test_initialize_onlyOnce() public {
        CreditPool.InitParams memory ip;
        vm.expectRevert();
        pool.initialize(ip);
    }

    function test_redeemableAssets() public {
        // senior first call on all cash, junior only above subordination
        assertEq(pool.redeemableAssets(true), 800_000 * USD);
        assertEq(pool.redeemableAssets(false), 0, "junior exactly at minimum");
        _deposit(bob, false, 100_000 * USD);
        assertEq(pool.redeemableAssets(false), 100_000 * USD);
    }

    function test_executeRedemption_onlyEpochs() public {
        vm.expectRevert(CreditPool.Unauthorized.selector);
        pool.executeRedemption(true, 1);
    }

    function test_defaultableAt() public {
        assertEq(pool.defaultableAt(12345), type(uint256).max);
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        assertEq(pool.defaultableAt(id), block.timestamp + 30 days + 5 days + 30 days);
    }

    function test_onlyDefaultManagerHooks() public {
        vm.expectRevert(CreditPool.Unauthorized.selector);
        pool.markPastDue(1);
        vm.expectRevert(CreditPool.Unauthorized.selector);
        pool.writeOff(1);
    }
}
