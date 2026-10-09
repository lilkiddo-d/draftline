/**
 * Draftline chain configuration — single source of truth for the frontend and keeper.
 * Mirrored for Solidity in contracts/script/ChainConfig.sol.
 *
 * Every value below was taken from an official source and verified on-chain (cast) on 2026-10-08.
 * Never add an address here without a source link.
 */

export type Address = `0x${string}`;

export interface DraftlineChain {
  id: number;
  name: string;
  nativeCurrency: { name: string; symbol: string; decimals: number };
  rpcUrls: { public: string; alchemyTemplate?: string; websocket?: string };
  explorer: { name: string; url: string; apiUrl: string };
  verification: { verifier: "blockscout"; verifierUrl: string };
  stablecoin: { symbol: string; name: string; address: Address; decimals: number };
  oracles: {
    provider: "chainlink";
    stablecoinUsd: { address: Address; decimals: number; heartbeatSeconds: number };
    ethUsd: { address: Address; decimals: number; heartbeatSeconds: number };
    /** null = not published for this chain (gap documented in DECISIONS.md). */
    sequencerUptime: Address | null;
  };
  weth: Address;
  multicall3: Address;
  sources: Record<string, string>;
}

export const robinhoodChain: DraftlineChain = {
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    public: "https://rpc.mainnet.chain.robinhood.com", // rate-limited; use a dedicated RPC in production
    alchemyTemplate: "https://robinhood-mainnet.g.alchemy.com/v2/{API_KEY}",
    websocket: "wss://feed.mainnet.chain.robinhood.com",
  },
  explorer: {
    name: "Blockscout",
    url: "https://robinhoodchain.blockscout.com",
    apiUrl: "https://robinhoodchain.blockscout.com/api/",
  },
  verification: { verifier: "blockscout", verifierUrl: "https://robinhoodchain.blockscout.com/api/" },
  stablecoin: {
    symbol: "USDG",
    name: "Global Dollar",
    address: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
    decimals: 6,
  },
  oracles: {
    provider: "chainlink",
    stablecoinUsd: { address: "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2", decimals: 8, heartbeatSeconds: 86_400 },
    ethUsd: { address: "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9", decimals: 8, heartbeatSeconds: 86_400 },
    sequencerUptime: null,
  },
  weth: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  multicall3: "0xcA11bde05977b3631167028862bE2a173976CA11",
  sources: {
    network: "https://docs.robinhood.com/chain/connecting",
    deployAndVerify: "https://docs.robinhood.com/chain/deploy-smart-contracts/",
    tokenContracts: "https://docs.robinhood.com/chain/contracts",
    oracles: "https://docs.robinhood.com/chain/oracles-and-price-feeds",
    chainlinkFeeds: "https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood",
    chainlinkFeedsJson: "https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json",
    sequencerFeeds: "https://docs.chain.link/data-feeds/l2-sequencer-feeds",
    multicall3: "https://www.multicall3.com (code verified on-chain at the canonical address)",
  },
};

/** Local anvil fork of Robinhood Chain mainnet (`anvil --fork-url ... --chain-id 31337`). */
export const robinhoodLocalFork: DraftlineChain = {
  ...robinhoodChain,
  id: 31337,
  name: "Robinhood Chain (local fork)",
  rpcUrls: { public: "http://127.0.0.1:8546" },
  explorer: { name: "Local", url: "http://127.0.0.1:8546", apiUrl: "" },
};

export const chains = { [robinhoodChain.id]: robinhoodChain, [robinhoodLocalFork.id]: robinhoodLocalFork };
