// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Timelock} from "../src/governance/Timelock.sol";
import {Underwriting} from "../src/compliance/Underwriting.sol";
import {PoolFactory} from "../src/pool/PoolFactory.sol";
import {ProjectTokenHooks} from "../src/token/ProjectTokenHooks.sol";
import {PoolParams} from "../src/libraries/Types.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {AggregatorV3Interface} from "../src/interfaces/IDraftline.sol";

/// @title Governance
/// @notice Schedules and executes Timelock operations. Every call is two steps, at least 48h apart:
///           1. `--sig "<op>(...,false)"` schedules (signed by the TIMELOCK_PROPOSER account),
///           2. `--sig "<op>(...,true)"`  executes once ready (anyone may execute).
///         The operation id is derived from the calldata, so step 2 must use identical arguments.
///         If the proposer is a Safe, use `--sig "...(...,false)"` without --broadcast to print the
///         target + calldata and submit the schedule() call through the Safe UI instead.
contract Governance is Script {
    using stdJson for string;

    uint256 constant USD = 1e6;

    // ------------------------------------------------------------------ operations

    /// @notice Activates every $DRFT feature. Callable exactly once, ever.
    function setProjectToken(address token, bool execute) external {
        _op(_addr(".projectTokenHooks"), abi.encodeCall(ProjectTokenHooks.setProjectToken, (token)), execute);
    }

    /// @notice Registers an AggregatorV3-compatible USD price source for `token` (needed for $DRFT backstop sizing).
    function setOracleFeed(address token, address feed, uint32 heartbeat, bool execute) external {
        _op(
            _addr(".oracleAdapter"),
            abi.encodeCall(OracleAdapter.setFeed, (token, AggregatorV3Interface(feed), heartbeat)),
            execute
        );
    }

    /// @notice Approves a KYC'd Pool Delegate (the compliance officer must have recorded their KYC first).
    function approveDelegate(address delegate, string calldata metadataURI, bool execute) external {
        _op(_addr(".underwriting"), abi.encodeCall(Underwriting.approveDelegate, (delegate, metadataURI)), execute);
    }

    /// @notice Opens a pool for an approved delegate with the conservative default parameters below.
    ///         Tune later with CreditPool.setParams (also via the Timelock).
    function createPool(address delegate, string calldata name, string calldata symbol, bool execute) external {
        PoolFactory.CreatePoolArgs memory a = PoolFactory.CreatePoolArgs({
            asset: _addr(".asset"),
            delegate: delegate,
            name: name,
            symbol: symbol,
            epochDuration: 30 days,
            params: defaultParams()
        });
        _op(_addr(".poolFactory"), abi.encodeCall(PoolFactory.createPool, (a)), execute);
    }

    function defaultParams() public pure returns (PoolParams memory p) {
        p.advanceRateBps = 8_000; // advance up to 80% of face value
        p.maxSeniorRatioBps = 8_000; // >= 20% junior subordination
        p.seniorRateBps = 800; // 8% senior target APR
        p.juniorHurdleBps = 1_400; // 14% junior hurdle
        p.protocolFeeBps = 1_000; // 10% of excess spread
        p.delegateFeeBps = 1_000; // 10% of excess spread (credited to first-loss)
        p.minFirstLossBps = 500; // first-loss >= 5% of outstanding
        p.lateFeeBps = 200;
        p.maxFeeBps = 1_000;
        p.maxBorrowerConcentrationBps = 2_500; // single borrower <= 25% of NAV
        p.maxActiveLoans = 100;
        p.gracePeriod = 5 days;
        p.defaultWindow = 30 days;
        p.maxTenor = 120 days;
        p.poolCap = uint128(2_000_000 * USD); // start small; raise via setParams
        p.minFirstLossAmount = uint128(50_000 * USD);
    }

    // ------------------------------------------------------------------ plumbing

    function _op(address target, bytes memory data, bool execute) internal {
        Timelock t = Timelock(payable(_addr(".timelock")));
        bytes32 salt = keccak256(data);
        bytes32 id = t.hashOperation(target, 0, data, bytes32(0), salt);
        console2.log("Timelock:", address(t));
        console2.log("Target:", target);
        console2.log("Calldata:");
        console2.logBytes(data);
        console2.log("Salt / operation id:");
        console2.logBytes32(salt);
        console2.logBytes32(id);
        if (!execute) {
            require(!t.isOperation(id), "already scheduled");
            uint256 delay = t.getMinDelay();
            vm.broadcast();
            t.schedule(target, 0, data, bytes32(0), salt, delay);
            console2.log("Scheduled. Executable after unix time:", block.timestamp + delay);
        } else {
            require(t.isOperationReady(id), "not ready (not scheduled, delay not passed, or already done)");
            vm.broadcast();
            t.execute(target, 0, data, bytes32(0), salt);
            console2.log("Executed.");
        }
    }

    function _addr(string memory key) internal view returns (address) {
        string memory path = string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".json");
        return vm.readFile(path).readAddress(key);
    }
}
