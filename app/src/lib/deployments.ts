import type { Address } from "viem";
import mainnet from "@/generated/deployment.4663.json";
import local from "@/generated/deployment.31337.json";
import { TARGET_CHAIN_ID } from "./chain";

export interface Deployment {
  chainId: number;
  deployedAtBlock?: number;
  asset: Address;
  timelock: Address;
  complianceRegistry: Address;
  underwriting: Address;
  invoiceNFT: Address;
  oracleAdapter: Address;
  feeCollector: Address;
  projectTokenHooks: Address;
  defaultManager: Address;
  poolFactory: Address;
  poolLens: Address;
}

const all = { 4663: mainnet, 31337: local } as unknown as Record<number, Partial<Deployment>>;

/** Written by script/Deploy.s.sol. Undefined until the protocol is deployed on the target chain. */
export const deployment: Deployment | undefined = (() => {
  const d = all[TARGET_CHAIN_ID];
  return d && d.poolFactory ? (d as Deployment) : undefined;
})();
