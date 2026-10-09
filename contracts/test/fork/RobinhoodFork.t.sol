// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {DeployCore} from "../../script/DeployCore.sol";
import {RobinhoodChain} from "../../script/ChainConfig.sol";
import {MockERC20, MockAggregator} from "../utils/Mocks.sol";
import {CreditPool} from "../../src/pool/CreditPool.sol";
import {Tranche} from "../../src/pool/Tranche.sol";
import {FirstLossVault} from "../../src/pool/FirstLossVault.sol";
import {EpochRedemptions} from "../../src/pool/EpochRedemptions.sol";
import {PoolFactory} from "../../src/pool/PoolFactory.sol";
import {PoolParams, LoanStatus} from "../../src/libraries/Types.sol";
import {AggregatorV3Interface} from "../../src/interfaces/IDraftline.sol";

/// @notice Runs the full protocol against Robinhood Chain mainnet state: real USDG (Paxos Global Dollar,
///         upgradeable proxy) and the real Chainlink USDG/USD feed.
/// @dev    RPC: $ROBINHOOD_RPC_URL or the public endpoint. Skips cleanly if the RPC is unreachable.
contract RobinhoodForkTest is Test, DeployCore {
    uint256 constant USD = 1e6;

    IERC20 usdg = IERC20(RobinhoodChain.USDG);
    Deployment d;
    CreditPool pool;
    Tranche senior;
    Tranche junior;
    FirstLossVault flv;
    EpochRedemptions epochs;

    address proposer = makeAddr("proposer");
    address guardian = makeAddr("guardian");
    address officer = makeAddr("officer");
    address delegate = makeAddr("delegate");
    address borrower = makeAddr("borrower");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address timelock;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(RobinhoodChain.PUBLIC_RPC));
        try vm.createSelectFork(rpc) {
            forked = true;
        } catch {
            return;
        }
        require(block.chainid == RobinhoodChain.CHAIN_ID, "wrong chain");

        d = _deployProtocol(
            DeployConfig({
                deployer: address(this),
                asset: RobinhoodChain.USDG,
                assetUsdFeed: RobinhoodChain.CHAINLINK_USDG_USD,
                assetFeedHeartbeat: RobinhoodChain.FEED_HEARTBEAT,
                proposer: proposer,
                guardian: guardian,
                complianceOfficer: officer,
                treasury: address(0),
                liquidator: address(0),
                timelockDelay: 48 hours,
                stakerShareBps: 3_000
            })
        );
        timelock = address(d.timelock);

        vm.startPrank(officer);
        d.compliance.setKyc(delegate, type(uint64).max);
        d.compliance.setKyc(borrower, type(uint64).max);
        vm.stopPrank();
        vm.prank(timelock);
        d.underwriting.approveDelegate(delegate, "ipfs://delegate");

        PoolParams memory p = PoolParams({
            advanceRateBps: 8_000,
            maxSeniorRatioBps: 8_000,
            seniorRateBps: 800,
            juniorHurdleBps: 1_200,
            protocolFeeBps: 1_000,
            delegateFeeBps: 1_000,
            minFirstLossBps: 500,
            lateFeeBps: 200,
            maxFeeBps: 1_000,
            maxBorrowerConcentrationBps: 5_000,
            maxActiveLoans: 100,
            gracePeriod: 5 days,
            defaultWindow: 30 days,
            maxTenor: 180 days,
            poolCap: uint128(5_000_000 * USD),
            minFirstLossAmount: uint128(10_000 * USD)
        });
        vm.prank(timelock);
        PoolFactory.PoolAddresses memory a = d.factory.createPool(
            PoolFactory.CreatePoolArgs({
                asset: RobinhoodChain.USDG,
                delegate: delegate,
                name: "Fork Receivables",
                symbol: "FORK",
                epochDuration: 30 days,
                params: p
            })
        );
        pool = CreditPool(a.pool);
        senior = Tranche(a.seniorTranche);
        junior = Tranche(a.juniorTranche);
        flv = FirstLossVault(a.firstLossVault);
        epochs = EpochRedemptions(a.epochRedemptions);
    }

    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
        }
        _;
    }

    function _give(address to, uint256 amount) internal {
        deal(address(usdg), to, amount);
    }

    function test_fork_realTokenAndFeed() public onlyForked {
        assertEq(IERC20Metadata(address(usdg)).decimals(), 6);
        assertEq(IERC20Metadata(address(usdg)).symbol(), "USDG");
        uint256 price = d.oracle.getPrice(address(usdg));
        assertApproxEqRel(price, 1e18, 0.02e18, "USDG ~ $1 on Chainlink");
        assertEq(AggregatorV3Interface(RobinhoodChain.CHAINLINK_USDG_USD).decimals(), 8);
    }

    function test_fork_fullLifecycle_repay() public onlyForked {
        _give(delegate, 50_000 * USD);
        vm.startPrank(delegate);
        usdg.approve(address(flv), type(uint256).max);
        flv.deposit(50_000 * USD);
        pool.approveBorrower(borrower, 500_000 * USD);
        vm.stopPrank();

        _give(bob, 200_000 * USD);
        vm.startPrank(bob);
        usdg.approve(address(junior), type(uint256).max);
        junior.deposit(200_000 * USD, bob);
        vm.stopPrank();
        _give(alice, 800_000 * USD);
        vm.startPrank(alice);
        usdg.approve(address(senior), type(uint256).max);
        senior.deposit(800_000 * USD, alice);
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(pool)), 1_000_000 * USD);

        vm.startPrank(borrower);
        uint256 id = d.invoiceNFT.mint(
            uint128(250_000 * USD), uint64(block.timestamp + 45 days), keccak256("debtor"), keccak256("INV-1"), "bafy-fork"
        );
        d.invoiceNFT.approve(address(pool), id);
        pool.submitInvoice(id);
        vm.stopPrank();
        vm.prank(delegate);
        pool.fundInvoice(id, 200_000 * USD, 300, keccak256("attestation"));
        assertEq(usdg.balanceOf(borrower), 200_000 * USD);

        vm.warp(block.timestamp + 40 days);
        uint256 owed = d.lens.amountOwed(pool, id);
        _give(borrower, owed);
        vm.startPrank(borrower);
        usdg.approve(address(pool), owed);
        pool.repay(id, owed);
        vm.stopPrank();
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.Repaid));
        assertGt(pool.seniorAssets(), 800_000 * USD, "senior earned its coupon");
        assertGt(pool.juniorAssets(), 200_000 * USD, "junior earned the residual");

        // Epoch redemption pays real USDG
        uint256 shares = senior.balanceOf(alice) / 2;
        vm.startPrank(alice);
        senior.approve(address(epochs), shares);
        epochs.requestRedeem(true, shares);
        vm.stopPrank();
        if (block.timestamp < epochs.epochEndsAt()) vm.warp(epochs.epochEndsAt());
        epochs.closeEpoch();
        vm.prank(alice);
        epochs.claim(true);
        assertGt(usdg.balanceOf(alice), 400_000 * USD);
        assertEq(pool.seniorAssets() + pool.juniorAssets(), pool.cash() + pool.outstandingPrincipal());
    }

    function test_fork_default_withBackstop() public onlyForked {
        _give(delegate, 20_000 * USD);
        vm.startPrank(delegate);
        usdg.approve(address(flv), type(uint256).max);
        flv.deposit(20_000 * USD);
        pool.approveBorrower(borrower, 500_000 * USD);
        vm.stopPrank();
        _give(bob, 100_000 * USD);
        vm.startPrank(bob);
        usdg.approve(address(junior), type(uint256).max);
        junior.deposit(100_000 * USD, bob);
        vm.stopPrank();
        _give(alice, 400_000 * USD);
        vm.startPrank(alice);
        usdg.approve(address(senior), type(uint256).max);
        senior.deposit(400_000 * USD, alice);
        vm.stopPrank();

        // Activate $DRFT backstop with a test token + test feed (real USDG/USD feed values the loss).
        MockERC20 drft = new MockERC20("Draftline", "DRFT", 18);
        MockAggregator drftFeed = new MockAggregator(8, 5e7); // $0.50
        vm.startPrank(timelock);
        d.hooks.setProjectToken(address(drft));
        d.oracle.setFeed(address(drft), AggregatorV3Interface(address(drftFeed)), 1 days);
        vm.stopPrank();
        drft.mint(bob, 1_000_000e18);
        vm.startPrank(bob);
        drft.approve(address(d.hooks), type(uint256).max);
        d.hooks.stake(1_000_000e18);
        vm.stopPrank();

        vm.startPrank(borrower);
        uint256 id = d.invoiceNFT.mint(
            uint128(300_000 * USD), uint64(block.timestamp + 30 days), keccak256("debtor2"), keccak256("INV-2"), "bafy"
        );
        d.invoiceNFT.approve(address(pool), id);
        pool.submitInvoice(id);
        vm.stopPrank();
        vm.prank(delegate);
        pool.fundInvoice(id, 240_000 * USD, 300, bytes32(0));

        vm.prank(delegate);
        d.defaultManager.declareDefault(address(pool), id);
        // 240k loss: 20k first-loss, 100k junior, 120k senior
        assertEq(flv.stake(), 0);
        assertEq(pool.juniorAssets(), 0);
        assertEq(pool.seniorAssets(), 280_000 * USD);
        uint256 slashed = drft.balanceOf(timelock); // liquidator defaults to treasury = Timelock
        // 120k USDG * real USDG price / $0.50
        uint256 usdgPrice = d.oracle.getPrice(address(usdg));
        assertApproxEqRel(slashed, 120_000e18 * usdgPrice / 0.5e18, 1e12);
    }
}
