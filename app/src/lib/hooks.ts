"use client";

import { useReadContract, useReadContracts } from "wagmi";
import type { Address } from "viem";
import { deployment } from "./deployments";
import { invoiceNFTAbi, poolLensAbi } from "@/generated/abis";

export function usePoolSummaries() {
  return useReadContract({
    address: deployment?.poolLens,
    abi: poolLensAbi,
    functionName: "summaries",
    args: deployment ? [deployment.poolFactory, 0n, 100n] : undefined,
    query: { enabled: !!deployment },
  });
}

export function usePoolSummary(pool?: Address) {
  return useReadContract({
    address: deployment?.poolLens,
    abi: poolLensAbi,
    functionName: "summary",
    args: pool ? [pool] : undefined,
    query: { enabled: !!deployment && !!pool },
  });
}

export const SCAN_WINDOW = 300n;

/**
 * Reads the most recent invoices (bounded window, no log scanning — the chain makes ~10 blocks/s, so
 * event range queries on public RPCs are impractical). Returns invoice data + current holder.
 */
export function useRecentInvoices() {
  const next = useReadContract({
    address: deployment?.invoiceNFT,
    abi: invoiceNFTAbi,
    functionName: "nextTokenId",
    query: { enabled: !!deployment },
  });
  const last = next.data ? next.data - 1n : 0n;
  const first = last > SCAN_WINDOW ? last - SCAN_WINDOW + 1n : 1n;
  const ids: bigint[] = [];
  for (let i = last; i >= first && i > 0n; i--) ids.push(i);

  const reads = useReadContracts({
    contracts: ids.flatMap((id) => [
      { address: deployment!.invoiceNFT, abi: invoiceNFTAbi, functionName: "getInvoice", args: [id] } as const,
      { address: deployment!.invoiceNFT, abi: invoiceNFTAbi, functionName: "ownerOf", args: [id] } as const,
    ]),
    query: { enabled: !!deployment && ids.length > 0 },
  });

  const invoices = ids
    .map((id, i) => {
      const inv = reads.data?.[i * 2]?.result as
        | {
            borrower: Address;
            dueDate: bigint;
            createdAt: bigint;
            status: number;
            financed: boolean;
            faceValue: bigint;
            debtorRefHash: `0x${string}`;
            invoiceNumberHash: `0x${string}`;
            docCID: string;
          }
        | undefined;
      const owner = reads.data?.[i * 2 + 1]?.result as Address | undefined;
      return inv ? { id, owner, ...inv } : undefined;
    })
    .filter((x): x is NonNullable<typeof x> => !!x);

  return { invoices, isLoading: next.isLoading || reads.isLoading, refetch: reads.refetch };
}

export type RecentInvoice = ReturnType<typeof useRecentInvoices>["invoices"][number];
