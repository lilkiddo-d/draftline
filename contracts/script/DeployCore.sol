// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Timelock} from "../src/governance/Timelock.sol";
import {ComplianceRegistry} from "../src/compliance/ComplianceRegistry.sol";
import {Underwriting} from "../src/compliance/Underwriting.sol";
import {InvoiceNFT} from "../src/pool/InvoiceNFT.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {FeeCollector} from "../src/token/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/token/ProjectTokenHooks.sol";
import {DefaultManager} from "../src/pool/DefaultManager.sol";
import {PoolFactory} from "../src/pool/PoolFactory.sol";
import {PoolLens} from "../src/pool/PoolLens.sol";
import {CreditPool} from "../src/pool/CreditPool.sol";
import {Tranche} from "../src/pool/Tranche.sol";
import {FirstLossVault} from "../src/pool/FirstLossVault.sol";
import {EpochRedemptions} from "../src/pool/EpochRedemptions.sol";
import {AggregatorV3Interface, IComplianceRegistry, IPoolRegistry, IProjectTokenHooks, IOracleAdapter} from
    "../src/interfaces/IDraftline.sol";

/// @notice Deployment + wiring + admin hand-off shared by script/Deploy.s.sol and the test suite, so tests
///         exercise exactly what ships.
abstract contract DeployCore {
    struct DeployConfig {
        address deployer; // tx sender; temporary admin until hand-off
        address asset; // pool stablecoin (USDG on Robinhood Chain)
        address assetUsdFeed; // Chainlink ASSET/USD feed (address(0) to skip)
        uint32 assetFeedHeartbeat;
        address proposer; // Timelock proposer (use a Safe in production)
        address guardian; // pause + revoke-delegate + timelock-cancel
        address complianceOfficer; // KYC operator
        address treasury; // protocol fee recipient (defaults to Timelock)
        address liquidator; // receives slashed $DRFT to sell for senior recovery (defaults to treasury)
        uint256 timelockDelay;
        uint16 stakerShareBps;
    }

    struct Deployment {
        Timelock timelock;
        ComplianceRegistry compliance;
        Underwriting underwriting;
        InvoiceNFT invoiceNFT;
        OracleAdapter oracle;
        FeeCollector feeCollector;
        ProjectTokenHooks hooks;
        DefaultManager defaultManager;
        PoolFactory factory;
        PoolLens lens;
        address creditPoolImpl;
        address trancheImpl;
        address firstLossVaultImpl;
        address epochRedemptionsImpl;
    }

    error HandoffFailed(address target);

    function _deployProtocol(DeployConfig memory c) internal returns (Deployment memory d) {
        address[] memory proposers = new address[](1);
        proposers[0] = c.proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open execution once the delay has passed
        d.timelock = new Timelock(c.timelockDelay, proposers, executors, c.guardian);

        address treasury = c.treasury == address(0) ? address(d.timelock) : c.treasury;
        address liquidator = c.liquidator == address(0) ? treasury : c.liquidator;

        d.compliance = new ComplianceRegistry(c.deployer, c.complianceOfficer);
        d.underwriting = new Underwriting(c.deployer, c.guardian, IComplianceRegistry(address(d.compliance)));
        d.invoiceNFT = new InvoiceNFT(c.deployer, c.guardian, IComplianceRegistry(address(d.compliance)));
        d.oracle = new OracleAdapter(c.deployer);
        d.feeCollector = new FeeCollector(c.deployer, c.guardian, c.asset, treasury, c.stakerShareBps);
        d.hooks = new ProjectTokenHooks(
            c.deployer, c.guardian, IERC20(c.asset), IOracleAdapter(address(d.oracle)), liquidator
        );
        d.defaultManager = new DefaultManager(c.deployer);

        d.creditPoolImpl = address(new CreditPool());
        d.trancheImpl = address(new Tranche());
        d.firstLossVaultImpl = address(new FirstLossVault());
        d.epochRedemptionsImpl = address(new EpochRedemptions());

        d.factory = new PoolFactory(
            c.deployer,
            c.guardian,
            PoolFactory.Implementations({
                creditPool: d.creditPoolImpl,
                tranche: d.trancheImpl,
                firstLossVault: d.firstLossVaultImpl,
                epochRedemptions: d.epochRedemptionsImpl
            }),
            PoolFactory.Dependencies({
                invoiceNFT: address(d.invoiceNFT),
                compliance: address(d.compliance),
                underwriting: address(d.underwriting),
                defaultManager: address(d.defaultManager),
                feeCollector: address(d.feeCollector)
            })
        );
        d.lens = new PoolLens();

        // ---- wiring
        if (c.assetUsdFeed != address(0)) {
            d.oracle.setFeed(c.asset, AggregatorV3Interface(c.assetUsdFeed), c.assetFeedHeartbeat);
        }
        d.invoiceNFT.setPoolRegistry(IPoolRegistry(address(d.factory)));
        d.defaultManager.setPoolRegistry(IPoolRegistry(address(d.factory)));
        d.defaultManager.setHooks(IProjectTokenHooks(address(d.hooks)));
        d.feeCollector.setHooks(IProjectTokenHooks(address(d.hooks)));
        d.hooks.setConfig(
            IOracleAdapter(address(d.oracle)), address(d.defaultManager), address(d.feeCollector), liquidator
        );
        d.factory.setAllowedAsset(c.asset, true);

        // ---- hand every admin role to the Timelock and drop the deployer's
        _handoff(address(d.compliance), c.deployer, address(d.timelock));
        _handoff(address(d.underwriting), c.deployer, address(d.timelock));
        _handoff(address(d.invoiceNFT), c.deployer, address(d.timelock));
        _handoff(address(d.oracle), c.deployer, address(d.timelock));
        _handoff(address(d.feeCollector), c.deployer, address(d.timelock));
        _handoff(address(d.hooks), c.deployer, address(d.timelock));
        _handoff(address(d.defaultManager), c.deployer, address(d.timelock));
        _handoff(address(d.factory), c.deployer, address(d.timelock));
    }

    function _handoff(address target, address deployer, address timelock) internal {
        bytes32 admin = 0x00;
        AccessControl(target).grantRole(admin, timelock);
        AccessControl(target).renounceRole(admin, deployer);
        if (AccessControl(target).hasRole(admin, deployer) || !AccessControl(target).hasRole(admin, timelock)) {
            revert HandoffFailed(target);
        }
    }
}
