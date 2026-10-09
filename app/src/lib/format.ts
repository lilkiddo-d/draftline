import { formatUnits, parseUnits } from "viem";
import { STABLE } from "./chain";

const YEAR = 365 * 24 * 3600;

export function fmtUsd(v: bigint | undefined, digits = 0): string {
  if (v === undefined) return "—";
  const n = Number(formatUnits(v, STABLE.decimals));
  return n.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function fmtBps(v: number | bigint | undefined, digits = 1): string {
  if (v === undefined) return "—";
  return `${(Number(v) / 100).toFixed(digits)}%`;
}

export function fmtPct(v: number | undefined, digits = 2): string {
  if (v === undefined || !Number.isFinite(v)) return "—";
  return `${(v * 100).toFixed(digits)}%`;
}

export function fmtDate(ts: bigint | number | undefined): string {
  if (ts === undefined) return "—";
  const n = Number(ts);
  if (!n) return "—";
  return new Date(n * 1000).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric" });
}

export function fmtDuration(seconds: number): string {
  if (seconds <= 0) return "now";
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return d > 0 ? `${d}d ${h}h` : h > 0 ? `${h}h ${m}m` : `${m}m`;
}

export function short(addr?: string) {
  return addr ? `${addr.slice(0, 6)}…${addr.slice(-4)}` : "—";
}

export function parseUsd(input: string): bigint | undefined {
  try {
    if (!input || Number(input) <= 0) return undefined;
    return parseUnits(input as `${number}`, STABLE.decimals);
  } catch {
    return undefined;
  }
}

/** Annualised realised return from a share price (1e18 = 1.0) since pool creation. */
export function realizedApy(sharePrice1e18: bigint, createdAt: bigint, now = Math.floor(Date.now() / 1000)): number | undefined {
  const elapsed = now - Number(createdAt);
  if (elapsed < 3600) return undefined;
  const growth = Number(sharePrice1e18) / 1e18 - 1;
  return (growth * YEAR) / elapsed;
}

export const LOAN_STATUS = ["None", "Submitted", "Funded", "Late", "Repaid", "Defaulted"] as const;
export const INVOICE_STATUS = ["None", "Minted", "Submitted", "Financed", "Repaid", "Defaulted", "Cancelled"] as const;
