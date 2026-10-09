// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {CreditPool} from "../../src/pool/CreditPool.sol";
import {Tranche} from "../../src/pool/Tranche.sol";
import {FirstLossVault} from "../../src/pool/FirstLossVault.sol";
import {EpochRedemptions} from "../../src/pool/EpochRedemptions.sol";
import {ICreditPool, ITranche} from "../../src/interfaces/IDraftline.sol";

/// @notice Fresh clones must reject zero-address / out-of-range initialisation.
contract InitGuardsTest is BaseTest {
    function test_tranche_zeroAddress() public {
        Tranche t = Tranche(Clones.clone(d.trancheImpl));
        vm.expectRevert(Tranche.ZeroAddress.selector);
        t.initialize(IERC20(address(0)), ICreditPool(address(pool)), address(epochs), true, "a", "b");
        assertEq(t.maxWithdraw(alice) + t.maxRedeem(alice), 0);
    }

    function test_epochs_guards() public {
        EpochRedemptions e = EpochRedemptions(Clones.clone(d.epochRedemptionsImpl));
        vm.expectRevert(EpochRedemptions.ZeroAddress.selector);
        e.initialize(ICreditPool(address(0)), ITranche(address(senior)), ITranche(address(junior)), usdg, 1 days);
        vm.expectRevert(EpochRedemptions.BadDuration.selector);
        e.initialize(ICreditPool(address(pool)), ITranche(address(senior)), ITranche(address(junior)), usdg, 1);
        vm.expectRevert(EpochRedemptions.BadDuration.selector);
        e.initialize(ICreditPool(address(pool)), ITranche(address(senior)), ITranche(address(junior)), usdg, 91 days);
    }

    function test_flv_zeroAddress() public {
        FirstLossVault f = FirstLossVault(Clones.clone(d.firstLossVaultImpl));
        vm.expectRevert(FirstLossVault.ZeroAddress.selector);
        f.initialize(ICreditPool(address(0)), usdg);
    }

    function test_pool_zeroAddress() public {
        CreditPool p = CreditPool(Clones.clone(d.creditPoolImpl));
        CreditPool.InitParams memory ip;
        vm.expectRevert(CreditPool.ZeroAddress.selector);
        p.initialize(ip);
    }

    function test_implementationsLocked() public {
        CreditPool.InitParams memory ip;
        vm.expectRevert();
        CreditPool(d.creditPoolImpl).initialize(ip);
        vm.expectRevert();
        FirstLossVault(d.firstLossVaultImpl).initialize(ICreditPool(address(pool)), usdg);
    }

    function test_kycView() public view {
        assertTrue(d.compliance.isKycValid(borrower));
        assertFalse(d.compliance.isKycValid(carol));
        assertEq(d.hooks.stakedBalanceOfShares(0), 0);
    }

    /// @dev Direct calls on the (uninitialised) implementation: views that need a pool revert, pure ones answer.
    function test_trancheImplementationDirect() public {
        Tranche impl = Tranche(d.trancheImpl);
        assertEq(impl.maxWithdraw(alice), 0);
        assertEq(impl.maxRedeem(alice), 0);
        vm.expectRevert();
        impl.totalAssets();
        vm.expectRevert();
        impl.maxDeposit(alice);
        vm.expectRevert();
        impl.maxMint(alice);
    }
}
