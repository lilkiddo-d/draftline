"use client";

import { useParams } from "next/navigation";
import { useEffect, useState } from "react";
import { erc20Abi, isAddress, maxUint256, type Address } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { CapitalBar, PoolStatus } from "@/components/PoolCards";
import { Empty, RequireWallet, Stat, TxStatus, useTx } from "@/components/ui";
import { creditPoolAbi, epochRedemptionsAbi, trancheAbi } from "@/generated/abis";
import { STABLE } from "@/lib/chain";
import { fmtBps, fmtDate, fmtDuration, fmtPct, fmtUsd, LOAN_STATUS, parseUsd, realizedApy, short } from "@/lib/format";
import { usePoolSummary } from "@/lib/hooks";

export default function PoolPage() {
  const params = useParams<{ address: string }>();
  const pool = (isAddress(params.address) ? params.address : undefined) as Address | undefined;
  const { data: s, isLoading } = usePoolSummary(pool);

  if (!pool) return <Empty>Invalid pool address.</Empty>;
  if (isLoading) return <Empty>Loading pool…</Empty>;
  if (!s) return <Empty>Pool not found.</Empty>;

  const total = s.seniorAssets + s.juniorAssets;
  const juniorShare = total ? Number((s.juniorAssets * 10_000n) / total) : 0;

  return (
    <>
      <div className="spread" style={{ marginBottom: 16 }}>
        <div>
          <h1>{s.name}</h1>
          <div className="row small muted">
            <PoolStatus s={s} /> Delegate <span className="mono">{short(s.delegate)}</span> · opened {fmtDate(s.createdAt)}
          </div>
        </div>
      </div>

      {s.impaired && (
        <div className="notice warn" style={{ marginBottom: 16 }}>
          A loan in this pool is past due. New deposits, epoch redemptions and first-loss withdrawals are paused
          until it is repaid or written off. Queued redemptions still bear any loss.
        </div>
      )}

      <div className="grid grid-4" style={{ marginBottom: 16 }}>
        <Stat label="Pool NAV" value={fmtUsd(total)} sub={`${fmtUsd(s.cash)} idle cash`} />
        <Stat label="Utilization" value={fmtBps(s.utilizationBps)} sub={`${s.activeLoans.toString()} active loans`} />
        <Stat
          label="Junior subordination"
          value={fmtBps(juniorShare)}
          sub={`min ${fmtBps(10_000 - s.params.maxSeniorRatioBps)}`}
        />
        <Stat
          label="First-loss cover"
          value={fmtUsd(s.firstLossStake)}
          sub={`required ${fmtUsd(s.requiredFirstLoss)}`}
        />
      </div>
      <div style={{ marginBottom: 16 }}>
        <CapitalBar s={s} />
      </div>

      <div className="grid grid-2" style={{ marginBottom: 16 }}>
        <TrancheCard pool={pool} s={s} senior />
        <TrancheCard pool={pool} s={s} senior={false} />
      </div>

      <div className="grid grid-2">
        <div className="card">
          <h2>Loss history</h2>
          <table>
            <tbody>
              <tr><td>Defaults</td><td>{s.losses.defaults.toString()}</td></tr>
              <tr><td>Total written off</td><td>{fmtUsd(s.losses.totalWrittenOff)}</td></tr>
              <tr><td>Absorbed by first-loss</td><td>{fmtUsd(s.losses.firstLossAbsorbed)}</td></tr>
              <tr><td>Absorbed by Junior</td><td>{fmtUsd(s.losses.juniorAbsorbed)}</td></tr>
              <tr><td>Absorbed by Senior</td><td>{fmtUsd(s.losses.seniorAbsorbed)}</td></tr>
              <tr><td>Recovered</td><td>{fmtUsd(s.losses.recovered)}</td></tr>
            </tbody>
          </table>
        </div>
        <div className="card">
          <h2>Terms</h2>
          <table>
            <tbody>
              <tr><td>Advance rate</td><td>up to {fmtBps(s.params.advanceRateBps)} of invoice</td></tr>
              <tr><td>Max tenor</td><td>{Math.round(s.params.maxTenor / 86400)} days</td></tr>
              <tr><td>Grace / default window</td><td>{Math.round(s.params.gracePeriod / 86400)}d / {Math.round(s.params.defaultWindow / 86400)}d</td></tr>
              <tr><td>Late fee</td><td>{fmtBps(s.params.lateFeeBps)} of principal</td></tr>
              <tr><td>Protocol / delegate fee</td><td>{fmtBps(s.params.protocolFeeBps)} / {fmtBps(s.params.delegateFeeBps)} of excess spread</td></tr>
              <tr><td>Single-borrower cap</td><td>{fmtBps(s.params.maxBorrowerConcentrationBps)} of NAV</td></tr>
              <tr><td>Pool cap</td><td>{fmtUsd(s.params.poolCap)} {STABLE.symbol}</td></tr>
            </tbody>
          </table>
        </div>
      </div>

      <LoansTable pool={pool} />
    </>
  );
}

type Summary = NonNullable<ReturnType<typeof usePoolSummary>["data"]>;

function TrancheCard({ pool, s, senior }: { pool: Address; s: Summary; senior: boolean }) {
  const { address: me } = useAccount();
  const tranche = senior ? s.seniorTranche : s.juniorTranche;
  const epochs = s.epochRedemptions;
  const [mode, setMode] = useState<"deposit" | "withdraw">("deposit");
  const [amount, setAmount] = useState("");
  const tx = useTx();
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);

  const user = me ?? "0x0000000000000000000000000000000000000000";
  const { data } = useReadContracts({
    contracts: [
      { address: tranche, abi: trancheAbi, functionName: "balanceOf", args: [user] },
      { address: s.asset, abi: erc20Abi, functionName: "balanceOf", args: [user] },
      { address: s.asset, abi: erc20Abi, functionName: "allowance", args: [user, tranche] },
      { address: pool, abi: creditPoolAbi, functionName: "maxDeposit", args: [senior, user] },
      { address: epochs, abi: epochRedemptionsAbi, functionName: "requestOf", args: [user, senior] },
      { address: epochs, abi: epochRedemptionsAbi, functionName: "claimable", args: [user, senior] },
      { address: tranche, abi: trancheAbi, functionName: "allowance", args: [user, epochs] },
    ],
    query: { enabled: !!me },
  });
  const shares = (data?.[0]?.result as bigint | undefined) ?? 0n;
  const wallet = (data?.[1]?.result as bigint | undefined) ?? 0n;
  const allowance = (data?.[2]?.result as bigint | undefined) ?? 0n;
  const maxDep = (data?.[3]?.result as bigint | undefined) ?? 0n;
  const req = data?.[4]?.result as { epoch: bigint; shares: bigint } | undefined;
  const claimable = data?.[5]?.result as readonly [bigint, bigint] | undefined;
  const shareAllowance = (data?.[6]?.result as bigint | undefined) ?? 0n;

  const { data: position } = useReadContract({
    address: tranche,
    abi: trancheAbi,
    functionName: "convertToAssets",
    args: [shares],
    query: { enabled: shares > 0n },
  });
  const { data: queuedValue } = useReadContract({
    address: tranche,
    abi: trancheAbi,
    functionName: "convertToAssets",
    args: [req?.shares ?? 0n],
    query: { enabled: !!req && req.shares > 0n },
  });

  const price = senior ? s.seniorSharePrice : s.juniorSharePrice;
  const apy = realizedApy(price, s.createdAt, now);
  const value = parseUsd(amount);
  const pendingThisEpoch = req && req.shares > 0n && req.epoch === s.currentEpoch;
  const claimReady = req && req.shares > 0n && req.epoch < s.currentEpoch;
  const epochLeft = Number(s.epochEndsAt) - now;

  async function deposit() {
    if (!value || !me) return;
    if (allowance < value) {
      const ok = await tx.send({ address: s.asset, abi: erc20Abi, functionName: "approve", args: [tranche, value] }, `Approve ${STABLE.symbol}`);
      if (!ok) return;
    }
    if (await tx.send({ address: tranche, abi: trancheAbi, functionName: "deposit", args: [value, me] }, "Deposit")) setAmount("");
  }

  async function requestRedeem() {
    if (!value) return;
    // Convert the asset amount to shares at the current price (capped at the full balance).
    const want = (value * 10n ** 18n) / (price || 1n) * 10n ** 6n;
    const sharesToQueue = want > shares ? shares : want;
    if (shareAllowance < sharesToQueue) {
      const ok = await tx.send({ address: tranche, abi: trancheAbi, functionName: "approve", args: [epochs, maxUint256] }, "Approve shares");
      if (!ok) return;
    }
    if (await tx.send({ address: epochs, abi: epochRedemptionsAbi, functionName: "requestRedeem", args: [senior, sharesToQueue] }, "Request withdrawal")) setAmount("");
  }

  return (
    <div className="card">
      <div className="spread">
        <h2 style={{ margin: 0 }}>
          <span className={`badge ${senior ? "senior" : "junior"}`}>{senior ? "Senior" : "Junior"}</span>
        </h2>
        <span className="small muted">{senior ? "Paid first, lower yield" : "First to absorb losses after first-loss cover"}</span>
      </div>
      <div className="grid grid-4" style={{ margin: "12px 0" }}>
        <div className="stat">
          <div className="label">NAV</div>
          <div className="value">{fmtUsd(senior ? s.seniorAssets : s.juniorAssets)}</div>
        </div>
        <div className="stat">
          <div className="label">{senior ? "Target APR" : "Hurdle APR"}</div>
          <div className="value">{fmtBps(senior ? s.params.seniorRateBps : s.params.juniorHurdleBps)}</div>
        </div>
        <div className="stat">
          <div className="label">Realized APY</div>
          <div className="value">{fmtPct(apy)}</div>
        </div>
        <div className="stat">
          <div className="label">Share price</div>
          <div className="value">{(Number(price) / 1e18).toFixed(4)}</div>
        </div>
      </div>

      <RequireWallet>
        <div className="small muted" style={{ marginBottom: 8 }}>
          Your position: <strong style={{ color: "var(--text)" }}>{fmtUsd(position as bigint | undefined, 2)} {STABLE.symbol}</strong> · wallet {fmtUsd(wallet, 2)}
        </div>
        <div className="tabs">
          <button className={mode === "deposit" ? "on" : ""} onClick={() => setMode("deposit")}>Deposit</button>
          <button className={mode === "withdraw" ? "on" : ""} onClick={() => setMode("withdraw")}>Withdraw (epoch)</button>
        </div>
        <div className="row">
          <input
            inputMode="decimal"
            placeholder={`Amount in ${STABLE.symbol}`}
            value={amount}
            onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))}
            style={{ flex: 1 }}
            aria-label="Amount"
          />
          {mode === "deposit" ? (
            <button className="btn" disabled={!value || value > maxDep || value > wallet || tx.busy} onClick={deposit}>
              Deposit
            </button>
          ) : (
            <button className="btn" disabled={!value || shares === 0n || tx.busy} onClick={requestRedeem}>
              Request
            </button>
          )}
        </div>
        <div className="small muted" style={{ marginTop: 6 }}>
          {mode === "deposit"
            ? maxDep === 0n
              ? senior
                ? "Senior is at its subordination cap. It reopens as Junior grows."
                : "Deposits are closed (paused, impaired, at cap, or not eligible)."
              : `Up to ${fmtUsd(maxDep)} ${STABLE.symbol} can be deposited now.`
            : `Requests are processed when the epoch closes (${fmtDuration(epochLeft)}), from idle cash${senior ? "" : ", only above the Junior subordination floor"}.`}
        </div>

        {(pendingThisEpoch || claimReady) && (
          <div className="card flat" style={{ marginTop: 12 }}>
            {pendingThisEpoch && (
              <div className="spread">
                <span className="small">
                  Queued for epoch #{req!.epoch.toString()}: ~{fmtUsd(queuedValue as bigint | undefined, 2)} {STABLE.symbol}
                </span>
                <button className="btn sm secondary" disabled={tx.busy} onClick={() => tx.send({ address: epochs, abi: epochRedemptionsAbi, functionName: "cancelRequest", args: [senior] }, "Cancel request")}>
                  Cancel
                </button>
              </div>
            )}
            {claimReady && (
              <div className="spread">
                <span className="small">
                  Epoch #{req!.epoch.toString()} processed: {fmtUsd(claimable?.[0], 2)} {STABLE.symbol} to claim
                  {claimable && claimable[1] > 0n ? " (partially filled — unfilled shares are returned)" : ""}
                </span>
                <button className="btn sm" disabled={tx.busy} onClick={() => tx.send({ address: epochs, abi: epochRedemptionsAbi, functionName: "claim", args: [senior] }, "Claim")}>
                  Claim
                </button>
              </div>
            )}
          </div>
        )}
        <TxStatus state={tx.state} />
      </RequireWallet>
    </div>
  );
}

function LoansTable({ pool }: { pool: Address }) {
  const { data: ids } = useReadContract({ address: pool, abi: creditPoolAbi, functionName: "activeLoans", args: [0n, 250n] });
  const { data: loans } = useReadContracts({
    contracts: (ids ?? []).map((id) => ({ address: pool, abi: creditPoolAbi, functionName: "getLoan", args: [id] }) as const),
    query: { enabled: !!ids?.length },
  });
  const now = Math.floor(Date.now() / 1000);
  return (
    <div className="card" style={{ marginTop: 16 }}>
      <h2>Active loans</h2>
      {!ids?.length ? (
        <Empty>No active loans.</Empty>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr><th>Invoice</th><th>Borrower</th><th>Principal owed</th><th>Fee owed</th><th>Due</th><th>Status</th></tr>
            </thead>
            <tbody>
              {ids.map((id, i) => {
                const l = loans?.[i]?.result;
                if (!l) return null;
                const late = Number(l.dueDate) < now;
                return (
                  <tr key={id.toString()}>
                    <td className="mono">#{id.toString()}</td>
                    <td className="mono">{short(l.borrower)}</td>
                    <td>{fmtUsd(l.principalOwed)}</td>
                    <td>{fmtUsd(l.feeOwed)}</td>
                    <td>{fmtDate(l.dueDate)}</td>
                    <td><span className={`badge ${late ? "warn" : "good"}`}>{late ? "Past due" : LOAN_STATUS[l.status]}</span></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
