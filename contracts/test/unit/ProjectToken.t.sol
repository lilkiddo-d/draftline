// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockERC20, MockAggregator} from "../utils/Mocks.sol";
import {ProjectTokenHooks} from "../../src/token/ProjectTokenHooks.sol";
import {FeeCollector} from "../../src/token/FeeCollector.sol";
import {Guarded} from "../../src/access/Guarded.sol";
import {IOracleAdapter, IProjectTokenHooks} from "../../src/interfaces/IDraftline.sol";

contract ProjectTokenTest is BaseTest {
    MockERC20 internal drft;
    ProjectTokenHooks internal hooks;
    FeeCollector internal fc;

    function setUp() public override {
        super.setUp();
        drft = new MockERC20("Draftline", "DRFT", 18);
        hooks = d.hooks;
        fc = d.feeCollector;
        drft.mint(alice, 1_000e18);
        drft.mint(bob, 1_000e18);
        vm.prank(alice);
        drft.approve(address(hooks), type(uint256).max);
        vm.prank(bob);
        drft.approve(address(hooks), type(uint256).max);
    }

    function _activate() internal {
        vm.prank(timelock);
        hooks.setProjectToken(address(drft));
    }

    // ================================================================ token-less operation

    function test_inactiveUntilSet() public {
        assertFalse(hooks.isActive());
        assertFalse(hooks.canReceiveRewards());
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.stake(1);
        // all protocol fees go to treasury
        usdg.mint(address(fc), 1_000 * USD);
        fc.distribute(address(usdg));
        assertEq(usdg.balanceOf(treasury), 1_000 * USD);
        // backstop returns 0 without reverting
        vm.prank(address(d.defaultManager));
        assertEq(hooks.coverSeniorLoss(address(pool), 1, 100), 0);
    }

    function test_setProjectToken_onceOnly() public {
        vm.startPrank(timelock);
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        hooks.setProjectToken(address(0));
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        hooks.setProjectToken(address(0xC0DE)); // no code
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        hooks.setProjectToken(address(usdg));
        hooks.setProjectToken(address(drft));
        vm.expectRevert(ProjectTokenHooks.TokenAlreadySet.selector);
        hooks.setProjectToken(address(drft));
        vm.stopPrank();
        vm.expectRevert();
        hooks.setProjectToken(address(drft));
    }

    // ================================================================ staking + rewards

    function test_stake_rewards_unstake() public {
        _activate();
        vm.prank(alice);
        hooks.stake(300e18);
        vm.prank(bob);
        hooks.stake(100e18);
        assertApproxEqAbs(hooks.stakedBalance(alice), 300e18, 1);
        assertTrue(hooks.canReceiveRewards());

        usdg.mint(address(fc), 1_000 * USD);
        fc.distribute(address(usdg));
        // 30% to stakers = 300, split 3:1
        assertEq(usdg.balanceOf(treasury), 700 * USD);
        assertApproxEqAbs(hooks.earned(alice), 225 * USD, 1);
        assertApproxEqAbs(hooks.earned(bob), 75 * USD, 1);

        vm.prank(alice);
        uint256 got = hooks.claimRewards();
        assertApproxEqAbs(got, 225 * USD, 1);
        vm.prank(alice);
        assertEq(hooks.claimRewards(), 0);

        uint256 aliceShares = hooks.sharesOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(ProjectTokenHooks.InsufficientShares.selector);
        hooks.requestUnstake(aliceShares + 1);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.requestUnstake(0);
        hooks.requestUnstake(aliceShares);
        (, uint64 unlockAt) = hooks.cooldowns(alice);
        vm.expectRevert(abi.encodeWithSelector(ProjectTokenHooks.CooldownActive.selector, unlockAt));
        hooks.unstake();
        vm.warp(unlockAt);
        uint256 out = hooks.unstake();
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.unstake();
        vm.stopPrank();
        assertApproxEqAbs(out, 300e18, 1);
        assertEq(hooks.sharesOf(alice), 0);
    }

    function test_slash_isProRata_andCooldownStillSlashable() public {
        _activate();
        MockAggregator feed = new MockAggregator(8, 1e8); // $1
        vm.prank(timelock);
        d.oracle.setFeed(address(drft), IAggregator(address(feed)), 1 days);
        vm.prank(alice);
        hooks.stake(600e18);
        vm.prank(bob);
        hooks.stake(400e18);
        uint256 aliceShares = hooks.sharesOf(alice);
        vm.prank(alice);
        hooks.requestUnstake(aliceShares); // in cooldown, still slashable

        vm.prank(address(d.defaultManager));
        uint256 slashed = hooks.coverSeniorLoss(address(pool), 1, 100 * USD);
        assertEq(slashed, 100e18);
        assertEq(drft.balanceOf(liquidator), 100e18);
        assertApproxEqAbs(hooks.stakedBalance(alice), 540e18, 1e6);
        assertApproxEqAbs(hooks.stakedBalance(bob), 360e18, 1e6);
    }

    function test_hooks_auth() public {
        vm.expectRevert(ProjectTokenHooks.Unauthorized.selector);
        hooks.notifyRewards(1);
        vm.expectRevert(ProjectTokenHooks.Unauthorized.selector);
        hooks.coverSeniorLoss(address(pool), 1, 1);
        vm.prank(address(fc));
        vm.expectRevert(ProjectTokenHooks.InsufficientShares.selector);
        hooks.notifyRewards(1);
        _activate();
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.stake(0);
    }

    function test_hooks_admin() public {
        vm.startPrank(timelock);
        vm.expectRevert(ProjectTokenHooks.BadParams.selector);
        hooks.setRiskParams(91 days, 100);
        vm.expectRevert(ProjectTokenHooks.BadParams.selector);
        hooks.setRiskParams(1 days, 5_001);
        hooks.setRiskParams(7 days, 1_000);
        assertEq(hooks.cooldownPeriod(), 7 days);
        vm.expectRevert(Guarded.ZeroAddress.selector);
        hooks.setConfig(IOracleAdapter(address(0)), address(0), address(0), address(0));
        hooks.setConfig(IOracleAdapter(address(0)), address(0), address(0), liquidator);
        vm.stopPrank();
        vm.prank(guardian);
        hooks.pause();
        _activate();
        vm.prank(alice);
        vm.expectRevert();
        hooks.stake(1);
        vm.expectRevert(Guarded.ZeroAddress.selector);
        new ProjectTokenHooks(address(this), address(0), IERC20(address(0)), IOracleAdapter(address(0)), liquidator);
    }

    // ================================================================ fee collector

    function test_feeCollector_admin() public {
        vm.startPrank(timelock);
        vm.expectRevert(FeeCollector.BadBps.selector);
        fc.setStakerShareBps(8_001);
        fc.setStakerShareBps(5_000);
        vm.expectRevert(Guarded.ZeroAddress.selector);
        fc.setTreasury(address(0));
        fc.setTreasury(carol);
        fc.setHooks(IProjectTokenHooks(address(0)));
        vm.stopPrank();
        usdg.mint(address(fc), 10);
        fc.distribute(address(usdg));
        assertEq(usdg.balanceOf(carol), 10);
        fc.distribute(address(usdg)); // zero balance no-op
        // non-reward tokens always go to treasury
        drft.mint(address(fc), 5);
        fc.distribute(address(drft));
        assertEq(drft.balanceOf(carol), 5);
        vm.expectRevert(FeeCollector.BadBps.selector);
        new FeeCollector(address(this), address(0), address(usdg), treasury, 9_000);
        vm.expectRevert(Guarded.ZeroAddress.selector);
        new FeeCollector(address(this), address(0), address(0), treasury, 0);
    }

    function test_feeCollector_paused() public {
        vm.prank(guardian);
        fc.pause();
        vm.expectRevert();
        fc.distribute(address(usdg));
        vm.prank(timelock);
        fc.unpause();
        vm.expectRevert();
        fc.pause();
    }
}

import {AggregatorV3Interface as IAggregator} from "../../src/interfaces/IDraftline.sol";
