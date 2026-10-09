"use client";

import { useQueryClient } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";
import { BaseError, type Abi } from "viem";
import { useAccount, usePublicClient, useWriteContract } from "wagmi";
import { activeChain, explorerTx } from "@/lib/chain";

export function Stat({ label, value, sub }: { label: string; value: ReactNode; sub?: ReactNode }) {
  return (
    <div className="card stat">
      <div className="label">{label}</div>
      <div className="value">{value}</div>
      {sub && <div className="sub">{sub}</div>}
    </div>
  );
}

type TxState = { status: "idle" | "pending" | "success" | "error"; message?: string; hash?: string };

export interface TxRequest {
  address: `0x${string}`;
  abi: Abi | readonly unknown[];
  functionName: string;
  args?: readonly unknown[];
}

/** Sends a contract write, waits for the receipt and refreshes every query. */
export function useTx() {
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();
  const qc = useQueryClient();
  const [state, setState] = useState<TxState>({ status: "idle" });

  async function send(req: TxRequest, label = "Transaction"): Promise<boolean> {
    setState({ status: "pending", message: `${label}: confirm in your wallet…` });
    try {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const hash = await writeContractAsync({ ...(req as any), chainId: activeChain.id });
      setState({ status: "pending", message: `${label}: waiting for confirmation…`, hash });
      const receipt = await publicClient!.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error("Transaction reverted");
      setState({ status: "success", message: `${label}: confirmed`, hash });
      await qc.invalidateQueries();
      return true;
    } catch (e) {
      const msg = e instanceof BaseError ? e.shortMessage : e instanceof Error ? e.message : String(e);
      setState({ status: "error", message: `${label} failed: ${msg}` });
      return false;
    }
  }
  return { state, send, busy: state.status === "pending" };
}

export function TxStatus({ state }: { state: TxState }) {
  if (state.status === "idle") return null;
  const link = state.hash ? explorerTx(state.hash) : null;
  return (
    <div className={`tx ${state.status}`} role="status">
      {state.message}{" "}
      {link && (
        <a href={link} target="_blank" rel="noreferrer">
          view
        </a>
      )}
    </div>
  );
}

export function RequireWallet({ children }: { children: ReactNode }) {
  const { isConnected } = useAccount();
  if (!isConnected) return <div className="notice">Connect a wallet to continue.</div>;
  return <>{children}</>;
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="notice muted">{children}</div>;
}
