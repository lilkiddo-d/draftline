// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {DeployCore} from "./DeployCore.sol";
import {RobinhoodChain} from "./ChainConfig.sol";

/// @title Deploy
/// @notice One-shot deploy of the whole Draftline protocol: deploys, wires, hands every admin role to the
///         48h Timelock, and writes deployments/<chainId>.json + app/src/generated/deployment.<chainId>.json.
///         Creates NO pools: pools need an Underwriting-approved delegate, which is a Timelock action.
///
///   Signing: only via the Foundry keystore account `draftline-deployer` (never a raw private key):
///     forge script script/Deploy.s.sol --rpc-url robinhood --account draftline-deployer \
///       --sender <deployer-address> --broadcast --verify --verifier blockscout \
///       --verifier-url https://robinhoodchain.blockscout.com/api/
///
///   Optional env (all default to the deployer unless noted):
///     TIMELOCK_PROPOSER   Safe/multisig that proposes Timelock operations
///     GUARDIAN            can pause, revoke delegates, cancel queued Timelock operations
///     COMPLIANCE_OFFICER  manages the KYC allowlist / blocklist
///     TREASURY            protocol fee recipient            (default: Timelock)
///     BACKSTOP_LIQUIDATOR receives slashed $DRFT to sell    (default: TREASURY)
///     STAKER_SHARE_BPS    share of protocol fees to $DRFT stakers once live (default 3000)
contract Deploy is Script, DeployCore {
    uint256 internal constant LOCAL_FORK_CHAIN_ID = 31337;

    function run() external returns (Deployment memory d) {
        uint256 chainId = block.chainid;
        require(
            chainId == RobinhoodChain.CHAIN_ID || chainId == LOCAL_FORK_CHAIN_ID,
            "Deploy: unsupported chain (Robinhood Chain mainnet 4663 or a local fork of it on 31337)"
        );
        // A 31337 node must be a fork of Robinhood Chain mainnet: USDG and the Chainlink feed must exist.
        require(RobinhoodChain.USDG.code.length > 0, "Deploy: USDG not found - is anvil forking mainnet?");
        require(RobinhoodChain.CHAINLINK_USDG_USD.code.length > 0, "Deploy: USDG/USD feed not found");

        address deployer = msg.sender;
        DeployConfig memory c = DeployConfig({
            deployer: deployer,
            asset: RobinhoodChain.USDG,
            assetUsdFeed: RobinhoodChain.CHAINLINK_USDG_USD,
            assetFeedHeartbeat: RobinhoodChain.FEED_HEARTBEAT,
            proposer: vm.envOr("TIMELOCK_PROPOSER", deployer),
            guardian: vm.envOr("GUARDIAN", deployer),
            complianceOfficer: vm.envOr("COMPLIANCE_OFFICER", deployer),
            treasury: vm.envOr("TREASURY", address(0)),
            liquidator: vm.envOr("BACKSTOP_LIQUIDATOR", address(0)),
            timelockDelay: 48 hours,
            stakerShareBps: uint16(vm.envOr("STAKER_SHARE_BPS", uint256(3_000)))
        });

        vm.startBroadcast(deployer);
        d = _deployProtocol(c);
        vm.stopBroadcast();

        _write(d, c, chainId);
        _log(d, c);
    }

    // ------------------------------------------------------------------ output

    function _write(Deployment memory d, DeployConfig memory c, uint256 chainId) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", chainId);
        vm.serializeUint(k, "deployedAtBlock", block.number);
        vm.serializeAddress(k, "deployer", c.deployer);
        vm.serializeAddress(k, "asset", c.asset);
        vm.serializeAddress(k, "assetUsdFeed", c.assetUsdFeed);
        vm.serializeAddress(k, "timelock", address(d.timelock));
        vm.serializeAddress(k, "timelockProposer", c.proposer);
        vm.serializeAddress(k, "guardian", c.guardian);
        vm.serializeAddress(k, "complianceOfficer", c.complianceOfficer);
        vm.serializeAddress(k, "complianceRegistry", address(d.compliance));
        vm.serializeAddress(k, "underwriting", address(d.underwriting));
        vm.serializeAddress(k, "invoiceNFT", address(d.invoiceNFT));
        vm.serializeAddress(k, "oracleAdapter", address(d.oracle));
        vm.serializeAddress(k, "feeCollector", address(d.feeCollector));
        vm.serializeAddress(k, "projectTokenHooks", address(d.hooks));
        vm.serializeAddress(k, "defaultManager", address(d.defaultManager));
        vm.serializeAddress(k, "poolFactory", address(d.factory));
        vm.serializeAddress(k, "poolLens", address(d.lens));
        vm.serializeAddress(k, "creditPoolImpl", d.creditPoolImpl);
        vm.serializeAddress(k, "trancheImpl", d.trancheImpl);
        vm.serializeAddress(k, "firstLossVaultImpl", d.firstLossVaultImpl);
        string memory json = vm.serializeAddress(k, "epochRedemptionsImpl", d.epochRedemptionsImpl);

        bool live = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory id = vm.toString(chainId);
        if (live) {
            vm.writeJson(json, string.concat(vm.projectRoot(), "/../deployments/", id, ".json"));
            vm.writeJson(json, string.concat(vm.projectRoot(), "/../app/src/generated/deployment.", id, ".json"));
        } else {
            // Simulations never overwrite real deployment records or the frontend config.
            vm.writeJson(json, string.concat(vm.projectRoot(), "/../deployments/dryrun-", id, ".json"));
        }
    }

    function _log(Deployment memory d, DeployConfig memory c) internal pure {
        console2.log("Timelock (admin of everything):", address(d.timelock));
        console2.log("  proposer:", c.proposer);
        console2.log("  guardian:", c.guardian);
        console2.log("PoolFactory:", address(d.factory));
        console2.log("InvoiceNFT:", address(d.invoiceNFT));
        console2.log("ComplianceRegistry:", address(d.compliance));
        console2.log("Underwriting:", address(d.underwriting));
        console2.log("DefaultManager:", address(d.defaultManager));
        console2.log("FeeCollector:", address(d.feeCollector));
        console2.log("ProjectTokenHooks:", address(d.hooks));
        console2.log("OracleAdapter:", address(d.oracle));
        console2.log("PoolLens:", address(d.lens));
        console2.log("No pools created. Next: approve a delegate via the Timelock (see DEPLOY.md).");
    }
}
