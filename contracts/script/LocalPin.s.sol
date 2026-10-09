// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {RobinhoodChain} from "./ChainConfig.sol";
import {AggregatorV3Interface} from "../src/interfaces/IDraftline.sol";

/// @title LocalPin
/// @notice LOCAL FORK ONLY. Anvil's state dump only contains locally-modified accounts, not read-only state
///         lazily fetched from the forked RPC. This script exercises every mainnet dependency Draftline uses
///         (USDG proxy + implementation, Chainlink USDG/USD proxy + aggregator, Multicall3), records the
///         accounts and storage slots touched, and writes them back to the node with anvil_setCode /
///         anvil_setStorageAt so that the snapshot is self-contained.
contract LocalPin is Script {
    address constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    address constant A = 0x1E2d000000000000000000000000000000000003; // demo lender (funded by LocalDemo)
    address constant B = 0xb022000000000000000000000000000000000002; // demo borrower

    function run() external {
        require(block.chainid == 31337, "LocalPin: local fork (31337) only");
        IERC20 usdg = IERC20(RobinhoodChain.USDG);
        AggregatorV3Interface feed = AggregatorV3Interface(RobinhoodChain.CHAINLINK_USDG_USD);

        vm.startStateDiffRecording();
        IERC20Metadata(address(usdg)).name();
        IERC20Metadata(address(usdg)).symbol();
        IERC20Metadata(address(usdg)).decimals();
        usdg.totalSupply();
        usdg.balanceOf(A);
        usdg.allowance(A, B);
        vm.prank(A);
        usdg.transfer(B, 1);
        vm.prank(A);
        usdg.approve(B, 1);
        vm.prank(B);
        usdg.transferFrom(A, B, 1);
        feed.latestRoundData();
        feed.decimals();
        feed.description();
        (bool ok,) = MULTICALL3.staticcall(abi.encodeWithSignature("getBlockNumber()"));
        require(ok, "multicall3 missing");
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();

        uint256 slots;
        address self = acc[0].accessor; // the ephemeral script contract that made the top-level calls
        for (uint256 i; i < acc.length; ++i) {
            address a = acc[i].account;
            if (a.code.length > 0 && a != self && a != address(vm) && a != CONSOLE) _pinCode(a);
            for (uint256 k; k < acc[i].storageAccesses.length; ++k) {
                VmSafe.StorageAccess memory s = acc[i].storageAccesses[k];
                if (s.account.code.length == 0 && s.account != A && s.account != B) continue;
                // Pin the pre-simulation value so the node state is unchanged, just made local.
                bytes32 v = s.isWrite ? s.previousValue : s.newValue;
                vm.rpc(
                    "anvil_setStorageAt",
                    string.concat('["', vm.toString(s.account), '","', vm.toString(s.slot), '","', vm.toString(v), '"]')
                );
                slots++;
            }
        }
        _pinCode(MULTICALL3);
        console2.log("pinned accounts:", acc.length, "slots:", slots);
    }

    function _pinCode(address a) private {
        vm.rpc("anvil_setCode", string.concat('["', vm.toString(a), '","', vm.toString(a.code), '"]'));
    }
}
