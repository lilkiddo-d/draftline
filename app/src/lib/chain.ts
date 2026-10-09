import { defineChain, type Address } from "viem";
import { robinhoodChain, robinhoodLocalFork, type DraftlineChain } from "@draftline/config";

export const TARGET_CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID || robinhoodChain.id);
const cfg: DraftlineChain = TARGET_CHAIN_ID === robinhoodLocalFork.id ? robinhoodLocalFork : robinhoodChain;
export const chainConfig = cfg;
export const isLocal = cfg.id === robinhoodLocalFork.id;

export const activeChain = defineChain({
  id: cfg.id,
  name: cfg.name,
  nativeCurrency: cfg.nativeCurrency,
  rpcUrls: { default: { http: [process.env.NEXT_PUBLIC_RPC_URL || cfg.rpcUrls.public] } },
  blockExplorers: isLocal ? undefined : { default: { name: cfg.explorer.name, url: cfg.explorer.url } },
  contracts: { multicall3: { address: cfg.multicall3 } },
});

export const STABLE = cfg.stablecoin;

/** $DRFT. Empty env = every token feature is hidden. */
export const PROJECT_TOKEN = (process.env.NEXT_PUBLIC_PROJECT_TOKEN || "").trim() as Address | "";
export const tokenFeaturesEnabled = /^0x[0-9a-fA-F]{40}$/.test(PROJECT_TOKEN);

export const localDevAccounts: Address[] = isLocal
  ? (process.env.NEXT_PUBLIC_LOCAL_DEV_ACCOUNTS || "")
      .split(",")
      .map((s) => s.trim())
      .filter((s): s is Address => /^0x[0-9a-fA-F]{40}$/.test(s))
  : [];

export function explorerTx(hash: string) {
  return isLocal ? null : `${cfg.explorer.url}/tx/${hash}`;
}
export function explorerAddress(addr: string) {
  return isLocal ? null : `${cfg.explorer.url}/address/${addr}`;
}
