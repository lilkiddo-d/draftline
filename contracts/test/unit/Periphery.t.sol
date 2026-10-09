// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockAggregator} from "../utils/Mocks.sol";
import {InvoiceNFT} from "../../src/pool/InvoiceNFT.sol";
import {ComplianceRegistry} from "../../src/compliance/ComplianceRegistry.sol";
import {Underwriting} from "../../src/compliance/Underwriting.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {PoolFactory} from "../../src/pool/PoolFactory.sol";
import {PoolLens} from "../../src/pool/PoolLens.sol";
import {CreditPool} from "../../src/pool/CreditPool.sol";
import {Timelock} from "../../src/governance/Timelock.sol";
import {Guarded} from "../../src/access/Guarded.sol";
import {InvoiceStatus, PoolParams} from "../../src/libraries/Types.sol";
import {AggregatorV3Interface, IComplianceRegistry, IPoolRegistry} from "../../src/interfaces/IDraftline.sol";

contract InvoiceNFTTest is BaseTest {
    bytes32 constant DEBTOR = keccak256("debtor-A");
    bytes32 constant NUM = keccak256("INV-0001");
    string constant CID = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";

    function test_mint_storesTerms() public {
        uint64 due = uint64(block.timestamp + 30 days);
        vm.prank(borrower);
        uint256 id = d.invoiceNFT.mint(100_000 * 1e6, due, DEBTOR, NUM, CID);
        InvoiceNFT.Invoice memory inv = d.invoiceNFT.getInvoice(id);
        assertEq(inv.borrower, borrower);
        assertEq(inv.faceValue, 100_000 * 1e6);
        assertEq(inv.dueDate, due);
        assertEq(inv.docCID, CID);
        assertEq(uint8(inv.status), uint8(InvoiceStatus.Minted));
        assertEq(d.invoiceNFT.ownerOf(id), borrower);
        assertEq(d.invoiceNFT.tokenOfKey(d.invoiceNFT.invoiceKey(DEBTOR, NUM)), id);
    }

    function test_mint_duplicateKeyRejected() public {
        uint64 due = uint64(block.timestamp + 30 days);
        vm.prank(borrower);
        uint256 id = d.invoiceNFT.mint(1, due, DEBTOR, NUM, CID);
        bytes32 key = d.invoiceNFT.invoiceKey(DEBTOR, NUM);
        // same borrower or any other borrower: the receivable can only ever be tokenised once
        vm.prank(borrower2);
        vm.expectRevert(abi.encodeWithSelector(InvoiceNFT.DuplicateInvoice.selector, key, id));
        d.invoiceNFT.mint(999, due, DEBTOR, NUM, "other");
        // even after cancel the key stays consumed
        vm.prank(borrower);
        d.invoiceNFT.cancel(id);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(InvoiceNFT.DuplicateInvoice.selector, key, id));
        d.invoiceNFT.mint(1, due, DEBTOR, NUM, CID);
    }

    function test_mint_validation() public {
        uint64 due = uint64(block.timestamp + 30 days);
        vm.startPrank(borrower);
        vm.expectRevert(InvoiceNFT.InvalidInvoice.selector);
        d.invoiceNFT.mint(0, due, DEBTOR, NUM, CID);
        vm.expectRevert(InvoiceNFT.InvalidInvoice.selector);
        d.invoiceNFT.mint(1, uint64(block.timestamp), DEBTOR, NUM, CID);
        vm.expectRevert(InvoiceNFT.InvalidInvoice.selector);
        d.invoiceNFT.mint(1, due, bytes32(0), NUM, CID);
        vm.expectRevert(InvoiceNFT.InvalidInvoice.selector);
        d.invoiceNFT.mint(1, due, DEBTOR, bytes32(0), CID);
        vm.expectRevert(InvoiceNFT.InvalidInvoice.selector);
        d.invoiceNFT.mint(1, due, DEBTOR, NUM, "");
        vm.expectRevert(InvoiceNFT.InvalidInvoice.selector);
        d.invoiceNFT.mint(1, due, DEBTOR, NUM, string(new bytes(129)));
        vm.stopPrank();
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(InvoiceNFT.NotCompliant.selector, carol));
        d.invoiceNFT.mint(1, due, DEBTOR, NUM, CID);
    }

    function test_mint_paused() public {
        vm.prank(guardian);
        d.invoiceNFT.pause();
        vm.prank(borrower);
        vm.expectRevert();
        d.invoiceNFT.mint(1, uint64(block.timestamp + 1 days), DEBTOR, NUM, CID);
        vm.prank(timelock);
        d.invoiceNFT.unpause();
    }

    function test_transferRestricted() public {
        uint256 id = _mintInvoice(borrower, 1, uint64(block.timestamp + 1 days));
        vm.prank(borrower);
        vm.expectRevert(InvoiceNFT.TransferRestricted.selector);
        d.invoiceNFT.transferFrom(borrower, carol, id);
    }

    function test_cancel_guards() public {
        uint256 id = _mintInvoice(borrower, 1, uint64(block.timestamp + 1 days));
        vm.prank(carol);
        vm.expectRevert(InvoiceNFT.NotHoldingPool.selector);
        d.invoiceNFT.cancel(id);
        vm.prank(delegate);
        pool.approveBorrower(borrower, 1);
        _submit(borrower, id);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(InvoiceNFT.BadStatus.selector, InvoiceStatus.Submitted));
        d.invoiceNFT.cancel(id);
    }

    function test_poolHooks_onlyHoldingPool() public {
        uint256 id = _mintInvoice(borrower, 1, uint64(block.timestamp + 1 days));
        vm.startPrank(carol);
        vm.expectRevert(InvoiceNFT.NotHoldingPool.selector);
        d.invoiceNFT.markSubmitted(id);
        vm.expectRevert(InvoiceNFT.NotHoldingPool.selector);
        d.invoiceNFT.markFinanced(id);
        vm.expectRevert(InvoiceNFT.NotHoldingPool.selector);
        d.invoiceNFT.markReleased(id);
        vm.expectRevert(InvoiceNFT.NotHoldingPool.selector);
        d.invoiceNFT.markRepaid(id);
        vm.expectRevert(InvoiceNFT.NotHoldingPool.selector);
        d.invoiceNFT.markDefaulted(id);
        vm.stopPrank();
        // a registered pool that does not hold the NFT is also rejected
        vm.prank(address(pool));
        vm.expectRevert(InvoiceNFT.NotHoldingPool.selector);
        d.invoiceNFT.markFinanced(id);
    }

    function test_financedOnce_latch() public {
        _seedLiquidity();
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(InvoiceNFT.AlreadyFinanced.selector, id));
        d.invoiceNFT.markFinanced(id);
        _repay(borrower, id, 82_400 * USD);
        // repaid invoice comes back to borrower but can never be pledged again
        vm.startPrank(borrower);
        d.invoiceNFT.approve(address(pool), id);
        vm.expectRevert(CreditPool.BadInvoice.selector);
        pool.submitInvoice(id);
        vm.stopPrank();
    }

    function test_setPoolRegistry_once() public {
        vm.prank(timelock);
        vm.expectRevert(InvoiceNFT.AlreadySet.selector);
        d.invoiceNFT.setPoolRegistry(IPoolRegistry(address(1)));
        InvoiceNFT fresh = new InvoiceNFT(address(this), address(0), IComplianceRegistry(address(d.compliance)));
        vm.expectRevert(Guarded.ZeroAddress.selector);
        fresh.setPoolRegistry(IPoolRegistry(address(0)));
        vm.expectRevert(Guarded.ZeroAddress.selector);
        new InvoiceNFT(address(this), address(0), IComplianceRegistry(address(0)));
        vm.expectRevert(Guarded.ZeroAddress.selector);
        new InvoiceNFT(address(0), address(0), IComplianceRegistry(address(d.compliance)));
    }

    function test_tokenURI_andInterfaces() public {
        uint256 id = _mintInvoice(borrower, 1, uint64(block.timestamp + 1 days));
        string memory uri = d.invoiceNFT.tokenURI(id);
        assertEq(bytes(uri).length > 30, true);
        assertTrue(d.invoiceNFT.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(d.invoiceNFT.supportsInterface(type(IAccessControl).interfaceId));
    }
}

contract ComplianceTest is BaseTest {
    function test_defaults() public view {
        assertTrue(d.compliance.requireBorrowerKyc());
        assertTrue(d.compliance.requireDelegateKyc());
        assertFalse(d.compliance.requireLenderKyc());
        assertTrue(d.compliance.canLend(carol));
        assertFalse(d.compliance.canBorrow(carol));
        assertFalse(d.compliance.canLend(address(0)));
    }

    function test_kycExpiry() public {
        vm.prank(officer);
        d.compliance.setKyc(carol, uint64(block.timestamp + 1 days));
        assertTrue(d.compliance.canBorrow(carol));
        vm.warp(block.timestamp + 1 days);
        assertFalse(d.compliance.canBorrow(carol));
    }

    function test_batch_andBlocklist() public {
        address[] memory list = new address[](2);
        list[0] = carol;
        list[1] = keeper;
        vm.prank(officer);
        d.compliance.setKycBatch(list, FAR);
        assertTrue(d.compliance.canDelegate(keeper));
        vm.prank(officer);
        d.compliance.setBlocked(carol, true);
        assertFalse(d.compliance.canBorrow(carol));
        assertFalse(d.compliance.canLend(carol));

        address[] memory big = new address[](201);
        vm.prank(officer);
        vm.expectRevert(ComplianceRegistry.BatchTooLarge.selector);
        d.compliance.setKycBatch(big, FAR);
        vm.startPrank(officer);
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        d.compliance.setKyc(address(0), FAR);
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        d.compliance.setBlocked(address(0), true);
        vm.stopPrank();
    }

    function test_requirements_onlyAdmin() public {
        vm.expectRevert();
        d.compliance.setRequirements(false, false, false);
        vm.prank(timelock);
        d.compliance.setRequirements(false, false, true);
        assertTrue(d.compliance.canBorrow(carol));
        assertFalse(d.compliance.canLend(carol));
        vm.expectRevert();
        d.compliance.setKyc(carol, FAR);
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        new ComplianceRegistry(address(0), address(0));
    }
}

contract UnderwritingTest is BaseTest {
    function test_approve_requiresKyc() public {
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(Underwriting.NotCompliant.selector, carol));
        d.underwriting.approveDelegate(carol, "");
        vm.prank(timelock);
        vm.expectRevert(Underwriting.ZeroAddress.selector);
        d.underwriting.approveDelegate(address(0), "");
        vm.expectRevert();
        d.underwriting.approveDelegate(delegate, "");
    }

    function test_revoke_byGuardianOrAdmin() public {
        assertTrue(d.underwriting.isActiveDelegate(delegate));
        assertEq(d.underwriting.delegateInfo(delegate).metadataURI, "ipfs://delegate-profile");
        vm.prank(carol);
        vm.expectRevert(Underwriting.Unauthorized.selector);
        d.underwriting.revokeDelegate(delegate);
        vm.prank(guardian);
        d.underwriting.revokeDelegate(delegate);
        assertFalse(d.underwriting.isActiveDelegate(delegate));
        vm.prank(timelock);
        d.underwriting.approveDelegate(delegate, "");
        vm.prank(timelock);
        d.underwriting.revokeDelegate(delegate);
        assertFalse(d.underwriting.isActiveDelegate(delegate));
    }

    function test_kycLapseDeactivates() public {
        vm.prank(officer);
        d.compliance.setKyc(delegate, 0);
        assertFalse(d.underwriting.isActiveDelegate(delegate));
        vm.expectRevert(Underwriting.ZeroAddress.selector);
        new Underwriting(address(0), address(0), IComplianceRegistry(address(0)));
    }
}

contract OracleTest is BaseTest {
    OracleAdapter internal o;
    MockAggregator internal f;
    address internal token = address(0xD0D0);

    function setUp() public override {
        super.setUp();
        o = new OracleAdapter(address(this));
        f = new MockAggregator(8, 250e8);
        o.setFeed(token, AggregatorV3Interface(address(f)), 1 days);
    }

    function test_price_scaling() public {
        assertEq(o.getPrice(token), 250e18);
        MockAggregator f18 = new MockAggregator(18, 3e18);
        o.setFeed(address(1), AggregatorV3Interface(address(f18)), 1 days);
        assertEq(o.getPrice(address(1)), 3e18);
        MockAggregator f20 = new MockAggregator(20, 4e20);
        o.setFeed(address(2), AggregatorV3Interface(address(f20)), 1 days);
        assertEq(o.getPrice(address(2)), 4e18);
    }

    function test_invalidAndStale() public {
        f.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, token));
        o.getPrice(token);
        f.set(1e8, block.timestamp - 1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, token, block.timestamp - 1 days - 1));
        o.getPrice(token);
        (bool ok, uint256 p) = o.tryGetPrice(token);
        assertFalse(ok);
        assertEq(p, 0);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoFeed.selector, address(9)));
        o.getPrice(address(9));
        f.setRevert(true);
        (ok,) = o.tryGetPrice(token);
        assertFalse(ok);
    }

    function test_sequencer() public {
        MockAggregator seq = new MockAggregator(0, 0);
        o.setSequencerUptimeFeed(AggregatorV3Interface(address(seq)), 1 hours);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        o.getPrice(token); // still inside grace period
        vm.warp(block.timestamp + 2 hours);
        f.set(250e8, block.timestamp);
        assertEq(o.getPrice(token), 250e18);
        seq.set(1, block.timestamp);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        o.getPrice(token);
    }

    function test_admin() public {
        vm.expectRevert(OracleAdapter.BadHeartbeat.selector);
        o.setFeed(token, AggregatorV3Interface(address(f)), 0);
        vm.expectRevert(OracleAdapter.BadHeartbeat.selector);
        o.setFeed(token, AggregatorV3Interface(address(f)), 8 days);
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        o.setFeed(address(0), AggregatorV3Interface(address(f)), 1);
        o.setFeed(token, AggregatorV3Interface(address(0)), 0);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoFeed.selector, token));
        o.getPrice(token);
        vm.prank(carol);
        vm.expectRevert();
        o.setFeed(token, AggregatorV3Interface(address(f)), 1);
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        new OracleAdapter(address(0));
    }

    function test_deployedUsdgFeed() public view {
        assertEq(d.oracle.getPrice(address(usdg)), 1e18);
    }
}

contract FactoryTest is BaseTest {
    function test_registry() public view {
        assertTrue(d.factory.isPool(address(pool)));
        assertEq(d.factory.poolCount(), 1);
        assertEq(d.factory.getPools(0, 10)[0], address(pool));
        assertEq(d.factory.getPools(1, 10).length, 0);
        assertTrue(d.factory.allowedAsset(address(usdg)));
    }

    function test_createPool_guards() public {
        PoolFactory.CreatePoolArgs memory a = PoolFactory.CreatePoolArgs({
            asset: address(0xBAD),
            delegate: delegate,
            name: "x",
            symbol: "x",
            epochDuration: 30 days,
            params: defaultParams()
        });
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.AssetNotAllowed.selector, address(0xBAD)));
        d.factory.createPool(a);
        a.asset = address(usdg);
        a.delegate = carol;
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.DelegateNotApproved.selector, carol));
        d.factory.createPool(a);
        a.delegate = delegate;
        vm.expectRevert();
        d.factory.createPool(a); // not admin
        a.params.advanceRateBps = 0;
        vm.prank(timelock);
        vm.expectRevert(CreditPool.InvalidParams.selector);
        d.factory.createPool(a);
        vm.prank(guardian);
        d.factory.pause();
        a.params = defaultParams();
        vm.prank(timelock);
        vm.expectRevert();
        d.factory.createPool(a);
    }

    function test_admin_setters() public {
        vm.startPrank(timelock);
        vm.expectRevert(Guarded.ZeroAddress.selector);
        d.factory.setAllowedAsset(address(0), true);
        d.factory.setAllowedAsset(address(usdg), false);
        (address nft,,,,) = d.factory.dependencies();
        PoolFactory.Dependencies memory deps = PoolFactory.Dependencies(nft, address(1), address(2), address(3), address(4));
        d.factory.setDependencies(deps);
        deps.feeCollector = address(0);
        vm.expectRevert(Guarded.ZeroAddress.selector);
        d.factory.setDependencies(deps);
        vm.stopPrank();
    }

    function test_constructor_guards() public {
        PoolFactory.Implementations memory impl;
        PoolFactory.Dependencies memory deps;
        vm.expectRevert(Guarded.ZeroAddress.selector);
        new PoolFactory(address(this), address(0), impl, deps);
    }
}

contract GovernanceTest is BaseTest {
    function test_timelock_config() public view {
        Timelock t = d.timelock;
        assertEq(t.getMinDelay(), 48 hours);
        assertTrue(t.hasRole(t.PROPOSER_ROLE(), proposer));
        assertTrue(t.hasRole(t.CANCELLER_ROLE(), guardian));
        assertTrue(t.hasRole(t.EXECUTOR_ROLE(), address(0)));
        assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_deployerHasNoRoles() public view {
        bytes32 admin = 0x00;
        assertFalse(d.compliance.hasRole(admin, address(this)));
        assertFalse(d.underwriting.hasRole(admin, address(this)));
        assertFalse(d.invoiceNFT.hasRole(admin, address(this)));
        assertFalse(d.oracle.hasRole(admin, address(this)));
        assertFalse(d.feeCollector.hasRole(admin, address(this)));
        assertFalse(d.hooks.hasRole(admin, address(this)));
        assertFalse(d.defaultManager.hasRole(admin, address(this)));
        assertFalse(d.factory.hasRole(admin, address(this)));
        assertTrue(d.factory.hasRole(admin, timelock));
    }

    function test_timelock_minDelayFloor() public {
        address[] memory p = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(Timelock.DelayTooShort.selector, 47 hours));
        new Timelock(47 hours, p, p, address(0));
        Timelock t = new Timelock(48 hours, p, p, address(0));
        vm.prank(address(t));
        vm.expectRevert(abi.encodeWithSelector(Timelock.DelayTooShort.selector, 1 hours));
        t.updateDelay(1 hours);
        vm.prank(address(t));
        t.updateDelay(72 hours);
        assertEq(t.getMinDelay(), 72 hours);
    }

    /// @notice End-to-end: setProjectToken can only happen through a 48h-delayed Timelock operation.
    function test_setProjectToken_viaTimelock() public {
        address drft = address(new MockToken());
        bytes memory data = abi.encodeCall(d.hooks.setProjectToken, (drft));
        vm.expectRevert();
        d.hooks.setProjectToken(drft);

        vm.prank(proposer);
        d.timelock.schedule(address(d.hooks), 0, data, bytes32(0), bytes32("drft"), 48 hours);
        vm.expectRevert();
        d.timelock.execute(address(d.hooks), 0, data, bytes32(0), bytes32("drft"));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(keeper); // open executor
        d.timelock.execute(address(d.hooks), 0, data, bytes32(0), bytes32("drft"));
        assertEq(address(d.hooks.projectToken()), drft);
    }

    function test_guardianCanCancel() public {
        bytes memory data = abi.encodeCall(d.compliance.setRequirements, (false, false, false));
        vm.prank(proposer);
        d.timelock.schedule(address(d.compliance), 0, data, bytes32(0), bytes32("x"), 48 hours);
        bytes32 id = d.timelock.hashOperation(address(d.compliance), 0, data, bytes32(0), bytes32("x"));
        vm.prank(guardian);
        d.timelock.cancel(id);
        assertFalse(d.timelock.isOperation(id));
    }
}

contract LensTest is BaseTest {
    function test_summary() public {
        _seedLiquidity();
        uint256 id = _originate(100_000 * USD, 80_000 * USD, 300, 30 days);
        vm.warp(block.timestamp + 10 days);
        PoolLens.PoolSummary memory s = d.lens.summary(pool);
        assertEq(s.pool, address(pool));
        assertEq(s.outstandingPrincipal, 80_000 * USD);
        assertEq(s.utilizationBps, 800);
        assertEq(s.seniorSharePrice, 1e18);
        assertEq(s.firstLossStake, 50_000 * USD);
        assertEq(s.requiredFirstLoss, 10_000 * USD);
        assertEq(s.activeLoans, 1);
        assertGt(s.seniorInterestOwed, 0);
        assertFalse(s.impaired);
        assertTrue(s.active);
        PoolLens.PoolSummary[] memory all = d.lens.summaries(d.factory, 0, 10);
        assertEq(all.length, 1);

        (uint256[] memory m, uint256[] memory df) = d.lens.keeperWork(pool);
        assertEq(m.length, 0);
        assertEq(df.length, 0);
        vm.warp(block.timestamp + 21 days);
        (m, df) = d.lens.keeperWork(pool);
        assertEq(m.length, 1);
        assertEq(m[0], id);
        vm.warp(pool.defaultableAt(id));
        (m, df) = d.lens.keeperWork(pool);
        assertEq(df.length, 1);
        assertEq(d.lens.amountOwed(pool, 9999), 0);
    }

    function test_emptyPool() public view {
        PoolLens.PoolSummary memory s = d.lens.summary(pool);
        assertEq(s.utilizationBps, 0);
        (uint256 so, uint256 jo) = d.lens.pendingInterest(pool);
        assertEq(so + jo, 0);
    }
}

contract MockToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}
