// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployCore} from "../../script/DeployCore.sol";
import {MockERC20, MockAggregator} from "./Mocks.sol";
import {CreditPool} from "../../src/pool/CreditPool.sol";
import {Tranche} from "../../src/pool/Tranche.sol";
import {FirstLossVault} from "../../src/pool/FirstLossVault.sol";
import {EpochRedemptions} from "../../src/pool/EpochRedemptions.sol";
import {PoolFactory} from "../../src/pool/PoolFactory.sol";
import {PoolParams} from "../../src/libraries/Types.sol";

abstract contract BaseTest is Test, DeployCore {
    uint256 internal constant USD = 1e6;
    uint64 internal constant FAR = type(uint64).max;

    MockERC20 internal usdg;
    MockAggregator internal usdgFeed;
    Deployment internal d;

    address internal proposer = makeAddr("proposer");
    address internal guardian = makeAddr("guardian");
    address internal officer = makeAddr("officer");
    address internal treasury = makeAddr("treasury");
    address internal liquidator = makeAddr("liquidator");
    address internal delegate = makeAddr("delegate");
    address internal borrower = makeAddr("borrower");
    address internal borrower2 = makeAddr("borrower2");
    address internal debtor = makeAddr("debtor");
    address internal alice = makeAddr("alice"); // senior lender
    address internal bob = makeAddr("bob"); // junior lender
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");
    address internal timelock;

    CreditPool internal pool;
    Tranche internal senior;
    Tranche internal junior;
    FirstLossVault internal flv;
    EpochRedemptions internal epochs;

    uint256 internal invoiceNonce;

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        usdgFeed = new MockAggregator(8, 1e8);
        d = _deployProtocol(
            DeployConfig({
                deployer: address(this),
                asset: address(usdg),
                assetUsdFeed: address(usdgFeed),
                assetFeedHeartbeat: 1 days + 1 hours,
                proposer: proposer,
                guardian: guardian,
                complianceOfficer: officer,
                treasury: treasury,
                liquidator: liquidator,
                timelockDelay: 48 hours,
                stakerShareBps: 3_000
            })
        );
        timelock = address(d.timelock);

        vm.startPrank(officer);
        d.compliance.setKyc(delegate, FAR);
        d.compliance.setKyc(borrower, FAR);
        d.compliance.setKyc(borrower2, FAR);
        vm.stopPrank();

        vm.prank(timelock);
        d.underwriting.approveDelegate(delegate, "ipfs://delegate-profile");

        _usePool(_createPool(defaultParams()));

        // Delegate posts first-loss cover
        _fundFirstLoss(50_000 * USD);

        vm.prank(delegate);
        pool.approveBorrower(borrower, 600_000 * USD);
    }

    // ------------------------------------------------------------------ fixtures

    function defaultParams() internal pure returns (PoolParams memory p) {
        p.advanceRateBps = 8_000;
        p.maxSeniorRatioBps = 8_000;
        p.seniorRateBps = 800;
        p.juniorHurdleBps = 1_200;
        p.protocolFeeBps = 1_000;
        p.delegateFeeBps = 1_000;
        p.minFirstLossBps = 500;
        p.lateFeeBps = 200;
        p.maxFeeBps = 1_000;
        p.maxBorrowerConcentrationBps = 5_000;
        p.maxActiveLoans = 50;
        p.gracePeriod = 5 days;
        p.defaultWindow = 30 days;
        p.maxTenor = 180 days;
        p.poolCap = uint128(10_000_000 * USD);
        p.minFirstLossAmount = uint128(10_000 * USD);
    }

    function _createPool(PoolParams memory p) internal returns (CreditPool) {
        vm.prank(timelock);
        PoolFactory.PoolAddresses memory a = d.factory.createPool(
            PoolFactory.CreatePoolArgs({
                asset: address(usdg),
                delegate: delegate,
                name: "Acme Receivables I",
                symbol: "ACME1",
                epochDuration: 30 days,
                params: p
            })
        );
        return CreditPool(a.pool);
    }

    function _usePool(CreditPool p) internal {
        pool = p;
        senior = Tranche(address(p.seniorTranche()));
        junior = Tranche(address(p.juniorTranche()));
        flv = FirstLossVault(address(p.firstLossVault()));
        epochs = EpochRedemptions(p.epochRedemptions());
    }

    // ------------------------------------------------------------------ helpers

    function _fundFirstLoss(uint256 amount) internal {
        usdg.mint(delegate, amount);
        vm.startPrank(delegate);
        usdg.approve(address(flv), amount);
        flv.deposit(amount);
        vm.stopPrank();
    }

    function _deposit(address user, bool isSenior, uint256 amount) internal returns (uint256 shares) {
        Tranche t = isSenior ? senior : junior;
        usdg.mint(user, amount);
        vm.startPrank(user);
        usdg.approve(address(t), amount);
        shares = t.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Standard capital stack: 200k junior, 800k senior (exactly at the 80% senior cap).
    function _seedLiquidity() internal {
        _deposit(bob, false, 200_000 * USD);
        _deposit(alice, true, 800_000 * USD);
    }

    function _mintInvoice(address who, uint256 face, uint64 due) internal returns (uint256 id) {
        invoiceNonce++;
        vm.prank(who);
        id = d.invoiceNFT.mint(
            uint128(face),
            due,
            keccak256(abi.encode("debtor", invoiceNonce)),
            keccak256(abi.encode("inv", invoiceNonce)),
            "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"
        );
    }

    function _submit(address who, uint256 id) internal {
        vm.startPrank(who);
        d.invoiceNFT.approve(address(pool), id);
        pool.submitInvoice(id);
        vm.stopPrank();
    }

    function _fund(uint256 id, uint256 advance, uint16 feeBps) internal {
        vm.prank(delegate);
        pool.fundInvoice(id, advance, feeBps, keccak256(abi.encode("attestation", id)));
    }

    /// @dev Mint + submit + fund an invoice for `borrower`.
    function _originate(uint256 face, uint256 advance, uint16 feeBps, uint64 tenor) internal returns (uint256 id) {
        id = _mintInvoice(borrower, face, uint64(block.timestamp) + tenor);
        _submit(borrower, id);
        _fund(id, advance, feeBps);
    }

    function _repay(address payer, uint256 id, uint256 amount) internal returns (uint256 paid) {
        usdg.mint(payer, amount);
        vm.startPrank(payer);
        usdg.approve(address(pool), amount);
        paid = pool.repay(id, amount);
        vm.stopPrank();
    }

    function _recover(address payer, uint256 id, uint256 amount) internal {
        usdg.mint(payer, amount);
        vm.startPrank(payer);
        usdg.approve(address(pool), amount);
        pool.recover(id, amount);
        vm.stopPrank();
    }

    function _assertAccounting() internal view {
        assertEq(
            pool.seniorAssets() + pool.juniorAssets(),
            pool.cash() + pool.outstandingPrincipal(),
            "NAV identity broken"
        );
        assertGe(usdg.balanceOf(address(pool)), pool.cash(), "pool under-collateralised");
        assertGe(usdg.balanceOf(address(flv)), flv.stake(), "flv under-collateralised");
    }
}
