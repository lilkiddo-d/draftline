// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Robinhood Chain mainnet constants. Mirrors config/chains.ts (see that file for source links).
///         Every address here was read from official docs and verified on-chain on 2026-10-08.
library RobinhoodChain {
    uint256 internal constant CHAIN_ID = 4663;
    string internal constant PUBLIC_RPC = "https://rpc.mainnet.chain.robinhood.com";
    string internal constant BLOCKSCOUT_API = "https://robinhoodchain.blockscout.com/api/";

    /// @dev USDG (Global Dollar, Paxos) — docs.robinhood.com/chain/contracts. 6 decimals, upgradeable proxy.
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// @dev WETH — docs.robinhood.com/chain/contracts.
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    /// @dev Chainlink USDG/USD proxy — docs.chain.link (network=robinhood). 8 decimals, 24h heartbeat, 0.5% dev.
    address internal constant CHAINLINK_USDG_USD = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    /// @dev Chainlink ETH/USD proxy — docs.chain.link (network=robinhood). 8 decimals, 24h heartbeat.
    address internal constant CHAINLINK_ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    /// @dev Feed heartbeat is 86400s; allow 1h of slack before treating the answer as stale.
    uint32 internal constant FEED_HEARTBEAT = 86_400 + 3_600;
    /// @dev No Chainlink L2 sequencer-uptime feed is published for Robinhood Chain (gap documented in DECISIONS.md).
    address internal constant SEQUENCER_UPTIME_FEED = address(0);
}
