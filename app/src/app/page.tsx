"use client";

import { PoolTable } from "@/components/PoolCards";
import { Empty, Stat } from "@/components/ui";
import { STABLE } from "@/lib/chain";
import { deployment } from "@/lib/deployments";
import { fmtBps, fmtUsd } from "@/lib/format";
import { usePoolSummaries } from "@/lib/hooks";

export default function PoolsPage() {
  const { data: pools, isLoading, error } = usePoolSummaries();

  const tvl = pools?.reduce((a, p) => a + p.seniorAssets + p.juniorAssets, 0n) ?? 0n;
  const outstanding = pools?.reduce((a, p) => a + p.outstandingPrincipal, 0n) ?? 0n;
  const losses = pools?.reduce((a, p) => a + p.losses.totalWrittenOff, 0n) ?? 0n;
  const recovered = pools?.reduce((a, p) => a + p.losses.recovered, 0n) ?? 0n;

  return (
    <>
      <div className="spread" style={{ marginBottom: 20 }}>
        <div>
          <h1>Credit pools</h1>
          <p className="muted">
            Lend {STABLE.symbol} to vetted businesses against their invoices. Senior is paid first. Junior earns more
            and absorbs losses after the delegate&apos;s first-loss stake.
          </p>
        </div>
      </div>

      {!deployment ? (
        <Empty>Draftline is not deployed on this network yet.</Empty>
      ) : (
        <>
          <div className="grid grid-4" style={{ marginBottom: 16 }}>
            <Stat label="Total value locked" value={`${fmtUsd(tvl)} ${STABLE.symbol}`} />
            <Stat label="Outstanding loans" value={`${fmtUsd(outstanding)}`} sub={tvl ? `${fmtBps((outstanding * 10_000n) / tvl)} utilized` : undefined} />
            <Stat label="Pools" value={pools?.length ?? "—"} />
            <Stat label="Written off / recovered" value={`${fmtUsd(losses)} / ${fmtUsd(recovered)}`} />
          </div>
          {isLoading ? (
            <Empty>Loading pools…</Empty>
          ) : error ? (
            <div className="notice bad">Could not load pools: {error.message.split("\n")[0]}</div>
          ) : !pools?.length ? (
            <Empty>No pools yet. Pools are opened by governance once a delegate is approved.</Empty>
          ) : (
            <PoolTable pools={pools} />
          )}
        </>
      )}
    </>
  );
}
