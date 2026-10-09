"use client";

import Link from "next/link";
import { fmtBps, fmtPct, fmtUsd, realizedApy } from "@/lib/format";
import { STABLE } from "@/lib/chain";
import type { usePoolSummaries } from "@/lib/hooks";

type Summary = NonNullable<ReturnType<typeof usePoolSummaries>["data"]>[number];

export function CapitalBar({ s }: { s: Summary }) {
  const total = Number(s.seniorAssets + s.juniorAssets) || 1;
  return (
    <div className="bar" title="Senior / Junior split of pool NAV">
      <span style={{ width: `${(Number(s.seniorAssets) / total) * 100}%`, background: "var(--senior)" }} />
      <span style={{ width: `${(Number(s.juniorAssets) / total) * 100}%`, background: "var(--junior)" }} />
    </div>
  );
}

export function PoolStatus({ s }: { s: Summary }) {
  if (!s.active) return <span className="badge bad">Paused</span>;
  if (s.impaired) return <span className="badge warn">Loan past due</span>;
  return <span className="badge good">Active</span>;
}

export function PoolTable({ pools }: { pools: readonly Summary[] }) {
  return (
    <div className="card table-wrap">
      <table>
        <thead>
          <tr>
            <th>Pool</th>
            <th>NAV ({STABLE.symbol})</th>
            <th>Senior APR</th>
            <th>Junior APR</th>
            <th>Utilization</th>
            <th>Losses</th>
            <th>Status</th>
          </tr>
        </thead>
        <tbody>
          {pools.map((s) => {
            const sApy = realizedApy(s.seniorSharePrice, s.createdAt);
            const jApy = realizedApy(s.juniorSharePrice, s.createdAt);
            return (
              <tr key={s.pool}>
                <td>
                  <Link href={`/pools/${s.pool}`}>
                    <strong>{s.name}</strong>
                  </Link>
                  <div style={{ width: 140, marginTop: 6 }}>
                    <CapitalBar s={s} />
                  </div>
                </td>
                <td>{fmtUsd(s.seniorAssets + s.juniorAssets)}</td>
                <td>
                  <span className="badge senior">target {fmtBps(s.params.seniorRateBps)}</span>
                  <div className="small muted">realized {fmtPct(sApy)}</div>
                </td>
                <td>
                  <span className="badge junior">hurdle {fmtBps(s.params.juniorHurdleBps)}</span>
                  <div className="small muted">realized {fmtPct(jApy)}</div>
                </td>
                <td>{fmtBps(s.utilizationBps)}</td>
                <td>
                  {s.losses.defaults > 0n ? (
                    <span className="small">
                      {s.losses.defaults.toString()} default(s), {fmtUsd(s.losses.totalWrittenOff)} written off
                    </span>
                  ) : (
                    <span className="small muted">None</span>
                  )}
                </td>
                <td>
                  <PoolStatus s={s} />
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
