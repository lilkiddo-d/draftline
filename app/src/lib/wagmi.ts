import { connectorsForWallets, type Wallet } from "@rainbow-me/rainbowkit";
import {
  coinbaseWallet,
  injectedWallet,
  metaMaskWallet,
  rabbyWallet,
  walletConnectWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { createConfig, createConnector, http } from "wagmi";
import { mock } from "wagmi/connectors";
import { activeChain, isLocal, localDevAccounts } from "./chain";

const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID || "";

/**
 * Local-fork only: a wallet that sends unsigned transactions to anvil (`--auto-impersonate`), so the whole
 * app can be exercised without any private key. Never enabled for chain 4663.
 */
function localDevWallet(account: `0x${string}`, label: string): Wallet {
  return {
    id: `local-dev-${account.toLowerCase()}`,
    name: `Local dev: ${label}`,
    iconUrl:
      "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 28 28'><rect width='28' height='28' rx='6' fill='%23334155'/><text x='14' y='19' font-size='13' text-anchor='middle' fill='white' font-family='monospace'>L</text></svg>",
    iconBackground: "#334155",
    createConnector: (walletDetails) =>
      createConnector((config) => ({
        ...mock({ accounts: [account], features: { reconnect: true } })(config),
        ...walletDetails,
      })),
  };
}

const LOCAL_LABELS: Record<string, string> = {
  "0xde1e000000000000000000000000000000000001": "delegate",
  "0xb022000000000000000000000000000000000002": "borrower",
  "0x1e2d000000000000000000000000000000000003": "lender",
};

const walletGroups = [
  {
    groupName: "Wallets",
    wallets: [injectedWallet, metaMaskWallet, rabbyWallet, coinbaseWallet, ...(projectId ? [walletConnectWallet] : [])],
  },
];
if (isLocal && localDevAccounts.length) {
  walletGroups.unshift({
    groupName: "Local fork (no keys)",
    wallets: localDevAccounts.map((a) => () => localDevWallet(a, LOCAL_LABELS[a.toLowerCase()] ?? a.slice(0, 8))),
  });
}

const connectors = connectorsForWallets(walletGroups, {
  appName: "Draftline",
  projectId: projectId || "draftline-no-walletconnect",
});

export const wagmiConfig = createConfig({
  chains: [activeChain],
  connectors,
  transports: { [activeChain.id]: http() },
  ssr: true,
});
