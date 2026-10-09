// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EpochRedemptions} from "../../src/pool/EpochRedemptions.sol";
import {Tranche} from "../../src/pool/Tranche.sol";
import {FirstLossVault} from "../../src/pool/FirstLossVault.sol";
import {CreditPool} from "../../src/pool/CreditPool.sol";
import {ICreditPool, ITranche} from "../../src/interfaces/IDraftline.sol";
import {PoolParams} from "../../src/libraries/Types.sol";

contract EpochsTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _seedLiquidity();
    }

    function _request(address who, bool isSenior, uint256 shares) internal {
        Tranche t = isSenior ? senior : junior;
        vm.startPrank(who);
        t.approve(address(epochs), shares);
        epochs.requestRedeem(isSenior, shares);
        vm.stopPrank();
    }

    function _relaxLimits() internal {
        PoolParams memory p = defaultParams();
        p.maxBorrowerConcentrationBps = 10_000;
        vm.prank(timelock);
        pool.setParams(p);
        vm.prank(delegate);
        pool.approveBorrower(borrower, 10_000_000 * USD);
        _fundFirstLoss(100_000 * USD);
    }

    function _closeEpoch() internal {
        vm.warp(epochs.epochEndsAt());
        vm.prank(keeper);
        epochs.closeEpoch();
    }

    // ================================================================ request / cancel / claim

    function test_fullSeniorRedemption() public {
        uint256 shares = senior.balanceOf(alice) / 4;
        _request(alice, true, shares);
        assertEq(senior.balanceOf(address(epochs)), shares);
        (uint256 a0,) = epochs.claimable(alice, true);
        assertEq(a0, 0, "nothing before close");
        _closeEpoch();
        (uint256 assets, uint256 back) = epochs.claimable(alice, true);
        assertEq(assets, 200_000 * USD);
        assertEq(back, 0);
        vm.prank(alice);
        epochs.claim(true);
        assertEq(usdg.balanceOf(alice), 200_000 * USD);
        assertEq(pool.seniorAssets(), 600_000 * USD);
        assertEq(senior.totalSupply(), 600_000 * USD * 1e6);
        _assertAccounting();
    }

    function test_partialFill_proRata() public {
        // Deploy most cash so only 100k idle remains for senior requests.
        _relaxLimits();
        _originate(1_000_000 * USD, 450_000 * USD, 100, 30 days);
        _originate(1_000_000 * USD, 450_000 * USD, 100, 30 days);
        assertEq(pool.cash(), 100_000 * USD);

        uint256 aliceShares = senior.balanceOf(alice);
        _request(alice, true, aliceShares / 2); // 400k worth
        _closeEpoch();
        EpochRedemptions.EpochData memory e = epochs.epochData(0, true);
        assertTrue(e.processed);
        assertEq(e.assets, 100_000 * USD);
        (uint256 assets, uint256 back) = epochs.claimable(alice, true);
        assertEq(assets, 100_000 * USD);
        assertEq(back, aliceShares / 2 - e.fulfilled);
        vm.prank(alice);
        epochs.claim(true);
        assertEq(senior.balanceOf(alice), aliceShares - e.fulfilled);
        _assertAccounting();
    }

    function test_juniorLimitedBySubordination() public {
        _deposit(bob, false, 50_000 * USD); // junior 250k, senior 800k -> min junior 200k
        _request(bob, false, junior.balanceOf(bob));
        _closeEpoch();
        EpochRedemptions.EpochData memory e = epochs.epochData(0, false);
        assertEq(e.assets, 50_000 * USD);
        assertEq(pool.juniorAssets(), 200_000 * USD);
        vm.prank(bob);
        epochs.claim(false);
        assertEq(usdg.balanceOf(bob), 50_000 * USD);
    }

    function test_seniorPriorityOverJunior() public {
        _deposit(bob, false, 300_000 * USD); // junior 500k, senior 800k, cash 1.3M
        _relaxLimits();
        _originate(2_000_000 * USD, 600_000 * USD, 100, 30 days);
        _originate(2_000_000 * USD, 600_000 * USD, 100, 30 days); // cash 100k
        _request(alice, true, senior.balanceOf(alice) / 8); // 100k
        _request(bob, false, junior.balanceOf(bob) / 5); // 100k
        _closeEpoch();
        assertEq(epochs.epochData(0, true).assets, 100_000 * USD, "senior filled first");
        assertEq(epochs.epochData(0, false).assets, 0, "junior gets nothing");
    }

    function test_cancelRequest() public {
        uint256 shares = 1_000e12;
        _request(alice, true, shares);
        vm.prank(alice);
        epochs.cancelRequest(true);
        assertEq(epochs.epochData(0, true).requested, 0);
        vm.prank(alice);
        vm.expectRevert(EpochRedemptions.NotCancellable.selector);
        epochs.cancelRequest(true);

        _request(alice, true, shares);
        _closeEpoch();
        vm.prank(alice);
        vm.expectRevert(EpochRedemptions.NotCancellable.selector);
        epochs.cancelRequest(true);
    }

    function test_requestAutoClaimsPreviousEpoch() public {
        _request(alice, true, 1_000e12);
        _closeEpoch();
        _request(alice, true, 2_000e12);
        assertEq(usdg.balanceOf(alice), 1_000 * USD, "previous epoch auto-claimed");
        assertEq(epochs.requestOf(alice, true).epoch, 1);
        assertEq(epochs.requestOf(alice, true).shares, 2_000e12);
    }

    function test_claimGuards() public {
        vm.expectRevert(EpochRedemptions.NothingToClaim.selector);
        epochs.claim(true);
        _request(alice, true, 1_000e12);
        vm.prank(alice);
        vm.expectRevert(EpochRedemptions.NothingToClaim.selector);
        epochs.claim(true);
        vm.expectRevert(EpochRedemptions.ZeroAmount.selector);
        epochs.requestRedeem(true, 0);
    }

    function test_closeEpoch_guards() public {
        uint256 endsAt = epochs.epochEndsAt();
        vm.expectRevert(abi.encodeWithSelector(EpochRedemptions.EpochNotOver.selector, endsAt));
        epochs.closeEpoch();

        // impaired pool cannot process redemptions (no exit ahead of a known default)
        _originate(100_000 * USD, 80_000 * USD, 100, 10 days);
        _request(alice, true, 1_000e12);
        vm.warp(endsAt);
        vm.expectRevert(EpochRedemptions.PoolImpaired.selector);
        epochs.closeEpoch();

        vm.prank(guardian);
        pool.pause();
        vm.expectRevert(EpochRedemptions.PoolInactive.selector);
        epochs.closeEpoch();
        vm.expectRevert(EpochRedemptions.PoolInactive.selector);
        vm.prank(alice);
        epochs.requestRedeem(true, 1);
    }

    function test_queuedSharesAbsorbLoss() public {
        // Senior requests exit, but a default reaching senior happens before the epoch can close.
        uint256 id = _originate(500_000 * USD, 400_000 * USD, 100, 30 days);
        _request(alice, true, senior.balanceOf(alice));
        vm.warp(pool.defaultableAt(id));
        vm.expectRevert(EpochRedemptions.PoolImpaired.selector);
        epochs.closeEpoch();
        d.defaultManager.triggerDefault(address(pool), id);
        epochs.closeEpoch();
        (uint256 assets,) = epochs.claimable(alice, true);
        // senior NAV 800k -> 650k after the 150k senior write-down; alice's queued shares absorbed it.
        assertEq(assets, 650_000 * USD);
    }

    function test_emptyEpochCloses() public {
        _closeEpoch();
        assertEq(epochs.currentEpoch(), 1);
        assertTrue(epochs.epochData(0, true).processed);
    }

    function test_initGuards() public {
        vm.expectRevert();
        epochs.initialize(ICreditPool(address(pool)), ITranche(address(senior)), ITranche(address(junior)), usdg, 1 days);
    }

    // ================================================================ tranche specifics

    function test_tranche_instantExitDisabled() public {
        assertEq(senior.maxWithdraw(alice), 0);
        assertEq(senior.maxRedeem(alice), 0);
        vm.expectRevert(Tranche.UseEpochRedemptions.selector);
        senior.withdraw(1, alice, alice);
        vm.expectRevert(Tranche.UseEpochRedemptions.selector);
        senior.redeem(1, alice, alice);
    }

    function test_tranche_mint() public {
        uint256 shares = 1_000 * USD * 1e6;
        usdg.mint(carol, 1_000 * USD);
        vm.startPrank(carol);
        usdg.approve(address(junior), 1_000 * USD);
        junior.mint(shares, carol);
        vm.stopPrank();
        assertEq(junior.balanceOf(carol), shares);
    }

    function test_tranche_metadata() public view {
        assertEq(senior.name(), "Draftline Acme Receivables I Senior");
        assertEq(junior.symbol(), "dlJ-ACME1");
        assertEq(senior.decimals(), 12);
        assertTrue(senior.isSenior());
        assertFalse(junior.isSenior());
        assertEq(senior.asset(), address(usdg));
    }

    function test_tranche_transferCompliance() public {
        vm.startPrank(alice);
        senior.transfer(carol, 1);
        vm.stopPrank();
        vm.prank(officer);
        d.compliance.setBlocked(carol, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Tranche.NotCompliant.selector, carol));
        senior.transfer(carol, 1);
    }

    function test_tranche_burnOnlyPool() public {
        vm.expectRevert(Tranche.Unauthorized.selector);
        senior.burnFrom(alice, 1);
    }

    function test_tranche_initGuards() public {
        Tranche impl = Tranche(d.trancheImpl);
        vm.expectRevert();
        impl.initialize(usdg, ICreditPool(address(pool)), address(epochs), true, "x", "x");
    }

    // ================================================================ first-loss vault

    function test_flv_withdraw() public {
        vm.prank(carol);
        vm.expectRevert(FirstLossVault.Unauthorized.selector);
        flv.withdraw(1, carol);
        vm.startPrank(delegate);
        vm.expectRevert(FirstLossVault.ZeroAmount.selector);
        flv.withdraw(0, delegate);
        vm.expectRevert(FirstLossVault.ZeroAddress.selector);
        flv.withdraw(1, address(0));
        vm.expectRevert(abi.encodeWithSelector(FirstLossVault.BelowRequirement.selector, 9_999 * USD, 10_000 * USD));
        flv.withdraw(40_001 * USD, delegate);
        flv.withdraw(40_000 * USD, delegate);
        vm.stopPrank();
        assertEq(usdg.balanceOf(delegate), 40_000 * USD);
        assertEq(flv.stake(), 10_000 * USD);
    }

    function test_flv_withdrawBlockedWhenImpairedOrPaused() public {
        _originate(100_000 * USD, 80_000 * USD, 100, 10 days);
        vm.warp(block.timestamp + 11 days);
        vm.prank(delegate);
        vm.expectRevert(FirstLossVault.PoolImpaired.selector);
        flv.withdraw(1, delegate);
        vm.prank(guardian);
        pool.pause();
        vm.prank(delegate);
        vm.expectRevert(FirstLossVault.PoolInactive.selector);
        flv.withdraw(1, delegate);
    }

    function test_flv_onlyPoolHooks() public {
        vm.expectRevert(FirstLossVault.Unauthorized.selector);
        flv.slash(1);
        vm.expectRevert(FirstLossVault.Unauthorized.selector);
        flv.notifyDeposit(1);
        vm.expectRevert(FirstLossVault.ZeroAmount.selector);
        flv.deposit(0);
        vm.expectRevert();
        flv.initialize(ICreditPool(address(pool)), usdg);
    }

    function test_flv_slashCappedAtStake() public {
        vm.prank(address(pool));
        uint256 slashed = flv.slash(1_000_000 * USD);
        assertEq(slashed, 50_000 * USD);
        assertEq(flv.stake(), 0);
    }
}
