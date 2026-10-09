// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {MockERC20, MockAggregator} from "../utils/Mocks.sol";
import {CreditPool} from "../../src/pool/CreditPool.sol";
import {DefaultManager} from "../../src/pool/DefaultManager.sol";
import {ProjectTokenHooks} from "../../src/token/ProjectTokenHooks.sol";
import {LoanStatus, InvoiceStatus} from "../../src/libraries/Types.sol";
import {AggregatorV3Interface, IProjectTokenHooks, IPoolRegistry} from "../../src/interfaces/IDraftline.sol";

contract DefaultsTest is BaseTest {
    DefaultManager internal dm;

    function setUp() public override {
        super.setUp();
        _seedLiquidity();
        dm = d.defaultManager;
    }

    function _toDefaultable(uint256 id) internal {
        vm.warp(pool.defaultableAt(id));
    }

    // ================================================================ past due / timing

    function test_markPastDue() public {
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        vm.expectRevert(CreditPool.NotPastDue.selector);
        dm.markPastDue(address(pool), id);
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(keeper);
        dm.markPastDue(address(pool), id);
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.Late));
        vm.expectRevert(abi.encodeWithSelector(CreditPool.BadLoanStatus.selector, LoanStatus.Late));
        dm.markPastDue(address(pool), id);
        // late loan can still be repaid
        _repay(borrower, id, d.lens.amountOwed(pool, id));
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.Repaid));
    }

    function test_triggerDefault_onlyAfterWindow() public {
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        uint256 at = pool.defaultableAt(id);
        vm.warp(at - 1);
        vm.expectRevert(abi.encodeWithSelector(DefaultManager.NotDefaultable.selector, at));
        dm.triggerDefault(address(pool), id);
        vm.warp(at);
        vm.prank(keeper);
        dm.triggerDefault(address(pool), id);
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.Defaulted));
    }

    function test_unknownPool() public {
        vm.expectRevert(abi.encodeWithSelector(DefaultManager.UnknownPool.selector, address(0xBEEF)));
        dm.triggerDefault(address(0xBEEF), 1);
        vm.expectRevert(abi.encodeWithSelector(DefaultManager.UnknownPool.selector, address(0xBEEF)));
        dm.markPastDue(address(0xBEEF), 1);
        vm.expectRevert(abi.encodeWithSelector(DefaultManager.UnknownPool.selector, address(0xBEEF)));
        dm.declareDefault(address(0xBEEF), 1);
    }

    function test_declareDefault_auth() public {
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        vm.prank(carol);
        vm.expectRevert(DefaultManager.Unauthorized.selector);
        dm.declareDefault(address(pool), id);
        vm.prank(delegate);
        dm.declareDefault(address(pool), id); // early default (fraud) allowed before due date
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.Defaulted));
        _fundFirstLoss(50_000 * USD); // first default wiped the stake; delegate must re-post cover
        uint256 id2 = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        vm.prank(timelock);
        dm.declareDefault(address(pool), id2);
    }

    // ================================================================ loss ordering

    function test_loss_firstLossOnly() public {
        uint256 id = _originate(50_000 * USD, 40_000 * USD, 300, 30 days);
        _toDefaultable(id);
        uint256 jBefore = pool.juniorAssets();
        uint256 sBefore = pool.seniorAssets();
        dm.triggerDefault(address(pool), id);
        assertEq(flv.stake(), 10_000 * USD, "first-loss absorbs it all");
        assertEq(pool.juniorAssets(), jBefore);
        assertEq(pool.seniorAssets(), sBefore);
        assertEq(pool.firstLossWritedown(), 40_000 * USD);
        (uint256 defaults, uint256 written, uint256 fl, uint256 jr, uint256 sr,) = _loss();
        assertEq(defaults, 1);
        assertEq(written, 40_000 * USD);
        assertEq(fl, 40_000 * USD);
        assertEq(jr, 0);
        assertEq(sr, 0);
        (,,, InvoiceStatus st,) = d.invoiceNFT.terms(id);
        assertEq(uint8(st), uint8(InvoiceStatus.Defaulted));
        _assertAccounting();
    }

    function test_loss_firstLossThenJunior() public {
        uint256 id = _originate(500_000 * USD, 150_000 * USD, 300, 30 days);
        _toDefaultable(id);
        dm.triggerDefault(address(pool), id);
        assertEq(flv.stake(), 0);
        assertEq(pool.juniorAssets(), 100_000 * USD, "junior takes 100k after 50k first-loss");
        assertEq(pool.seniorAssets(), 800_000 * USD, "senior untouched");
        _assertAccounting();
    }

    function test_loss_reachesSenior_andBackstopInactive() public {
        // Allow a single 400k loan: concentration 50% OK, limit 600k OK.
        uint256 id = _originate(500_000 * USD, 400_000 * USD, 300, 30 days);
        _toDefaultable(id);
        vm.expectEmit(address(pool));
        emit CreditPool.LoanDefaulted(id, 400_000 * USD, 50_000 * USD, 200_000 * USD, 150_000 * USD);
        dm.triggerDefault(address(pool), id);
        assertEq(flv.stake(), 0);
        assertEq(pool.juniorAssets(), 0);
        assertEq(pool.seniorAssets(), 650_000 * USD);
        assertEq(pool.seniorWritedown(), 150_000 * USD);
        // wiped junior with live shares cannot take new deposits
        assertEq(pool.maxDeposit(false, carol), 0);
        _assertAccounting();
    }

    // ================================================================ recovery

    function test_recovery_waterfall_seniorThenJuniorThenFirstLoss() public {
        uint256 id = _originate(500_000 * USD, 400_000 * USD, 300, 30 days);
        _toDefaultable(id);
        dm.triggerDefault(address(pool), id);
        uint256 arrears = pool.seniorInterestOwed();
        assertGt(arrears, 0, "senior coupon accrued while the loan was outstanding");

        _recover(debtor, id, 100_000 * USD);
        assertEq(pool.seniorAssets(), 750_000 * USD, "senior principal restored first");
        assertEq(pool.seniorWritedown(), 50_000 * USD);
        assertEq(pool.juniorAssets(), 0);

        _recover(debtor, id, 100_000 * USD);
        assertEq(pool.seniorAssets(), 800_000 * USD + arrears, "then senior interest arrears");
        assertEq(pool.seniorInterestOwed(), 0);
        assertEq(pool.juniorAssets(), 50_000 * USD - arrears, "junior only after senior is current");

        _recover(debtor, id, 150_000 * USD + arrears);
        assertEq(pool.juniorAssets(), 200_000 * USD);
        assertEq(pool.juniorWritedown(), 0);
        assertEq(flv.stake(), 0, "first-loss restored last");

        _recover(debtor, id, 50_000 * USD);
        assertEq(flv.stake(), 50_000 * USD);

        uint256 fcBefore = usdg.balanceOf(address(d.feeCollector));
        _recover(debtor, id, 10_000 * USD); // excess recovery is income
        assertGt(usdg.balanceOf(address(d.feeCollector)), fcBefore);
        assertEq(pool.getLoan(id).recovered, 410_000 * USD + arrears);
        _assertAccounting();
    }

    function test_recover_guards() public {
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.BadLoanStatus.selector, LoanStatus.Funded));
        pool.recover(id, 1);
        vm.prank(delegate);
        dm.declareDefault(address(pool), id);
        vm.expectRevert(CreditPool.ZeroAmount.selector);
        pool.recover(id, 0);
    }

    function test_writeOff_cannotRepeat() public {
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        vm.prank(delegate);
        dm.declareDefault(address(pool), id);
        vm.prank(delegate);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.BadLoanStatus.selector, LoanStatus.Defaulted));
        dm.declareDefault(address(pool), id);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.BadLoanStatus.selector, LoanStatus.Defaulted));
        pool.repay(id, 1);
    }

    // ================================================================ $DRFT backstop

    function _activateBackstop() internal returns (MockERC20 drft, MockAggregator drftFeed) {
        drft = new MockERC20("Draftline", "DRFT", 18);
        drftFeed = new MockAggregator(8, 2e8); // $2.00
        vm.startPrank(timelock);
        d.hooks.setProjectToken(address(drft));
        d.oracle.setFeed(address(drft), AggregatorV3Interface(address(drftFeed)), 1 days);
        vm.stopPrank();
        drft.mint(carol, 1_000_000e18);
        vm.startPrank(carol);
        drft.approve(address(d.hooks), type(uint256).max);
        d.hooks.stake(1_000_000e18);
        vm.stopPrank();
    }

    function test_backstop_coversSeniorLoss() public {
        (MockERC20 drft, MockAggregator drftFeed) = _activateBackstop();
        uint256 id = _originate(500_000 * USD, 400_000 * USD, 300, 30 days);
        _toDefaultable(id);
        usdgFeed.set(1e8, block.timestamp);
        drftFeed.set(2e8, block.timestamp);
        vm.expectEmit(address(dm));
        emit DefaultManager.BackstopCovered(address(pool), id, 150_000 * USD, 75_000e18);
        dm.triggerDefault(address(pool), id);
        // 150k senior loss at $2/DRFT = 75k DRFT (cap 30% of 1M = 300k)
        assertEq(drft.balanceOf(liquidator), 75_000e18);
        assertEq(d.hooks.totalStaked(), 925_000e18);

        // liquidator sells and pays proceeds back -> senior restored
        _recover(liquidator, id, 150_000 * USD);
        assertEq(pool.seniorAssets(), 800_000 * USD);
    }

    function test_backstop_capped() public {
        (MockERC20 drft, MockAggregator feed) = _activateBackstop();
        feed.set(1e6, block.timestamp); // $0.01 -> would need 15M DRFT
        uint256 id = _originate(500_000 * USD, 400_000 * USD, 300, 30 days);
        vm.prank(delegate);
        dm.declareDefault(address(pool), id);
        assertEq(drft.balanceOf(liquidator), 300_000e18, "30% cap");
    }

    function test_backstop_stalePriceSkips() public {
        (MockERC20 drft, MockAggregator feed) = _activateBackstop();
        uint256 id = _originate(500_000 * USD, 400_000 * USD, 300, 30 days);
        _toDefaultable(id);
        feed.set(2e8, block.timestamp - 2 days); // stale
        usdgFeed.set(1e8, block.timestamp);
        dm.triggerDefault(address(pool), id);
        assertEq(drft.balanceOf(liquidator), 0);
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.Defaulted), "default still happens");
    }

    function test_backstop_revertDoesNotBlockDefault() public {
        RevertingHooks bad = new RevertingHooks();
        vm.prank(timelock);
        dm.setHooks(IProjectTokenHooks(address(bad)));
        uint256 id = _originate(500_000 * USD, 400_000 * USD, 300, 30 days);
        vm.expectEmit(address(dm));
        emit DefaultManager.BackstopFailed(address(pool), id, 150_000 * USD);
        vm.prank(delegate);
        dm.declareDefault(address(pool), id);
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.Defaulted));
    }

    function test_backstop_disabled() public {
        vm.prank(timelock);
        dm.setHooks(IProjectTokenHooks(address(0)));
        uint256 id = _originate(500_000 * USD, 400_000 * USD, 300, 30 days);
        vm.prank(delegate);
        dm.declareDefault(address(pool), id);
        assertEq(pool.seniorWritedown(), 150_000 * USD);
    }

    function test_dm_admin() public {
        vm.expectRevert();
        dm.setHooks(IProjectTokenHooks(address(0)));
        vm.prank(timelock);
        vm.expectRevert(DefaultManager.AlreadySet.selector);
        dm.setPoolRegistry(IPoolRegistry(address(d.factory)));
        vm.expectRevert(DefaultManager.ZeroAddress.selector);
        new DefaultManager(address(0));
        DefaultManager fresh = new DefaultManager(address(this));
        vm.expectRevert(DefaultManager.ZeroAddress.selector);
        fresh.setPoolRegistry(IPoolRegistry(address(0)));
    }

    function _loss() internal view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        (uint128 a, uint128 b, uint128 c, uint128 e, uint128 f, uint128 g) = pool.lossStats();
        return (a, b, c, e, f, g);
    }
}

contract RevertingHooks {
    function coverSeniorLoss(address, uint256, uint256) external pure returns (uint256) {
        revert("nope");
    }
}
