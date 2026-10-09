"use client";

import { useState } from "react";
import { erc20Abi, isAddress, keccak256, toBytes, type Address } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { Empty, RequireWallet, Stat, TxStatus, useTx } from "@/components/ui";
import {
  creditPoolAbi,
  defaultManagerAbi,
  epochRedemptionsAbi,
  firstLossVaultAbi,
  underwritingAbi,
} from "@/generated/abis";
import { STABLE } from "@/lib/chain";
import { deployment } from "@/lib/deployments";
import { fmtBps, fmtDate, fmtUsd, LOAN_STATUS, parseUsd, short } from "@/lib/format";
import { usePoolSummaries, useRecentInvoices } from "@/lib/hooks";

export default function DelegatePage() {
  return (
    <>
      <h1>Delegate dashboard</h1>
      <p className="muted">
        Underwrite borrowers, verify and fund invoices, manage your first-loss stake and service loans.
      </p>
      {!deployment ? <Empty>Draftline is not deployed on this network yet.</Empty> : <RequireWallet><Dashboard /></RequireWallet>}
    </>
  );
}

function Dashboard() {
  const { address: me } = useAccount();
  const { data: active } = useReadContract({
    address: deployment!.underwriting,
    abi: underwritingAbi,
    functionName: "isActiveDelegate",
    args: [me!],
  });
  const { data: pools } = usePoolSummaries();
  const mine = (pools ?? []).filter((p) => p.delegate.toLowerCase() === me!.toLowerCase());
  const [selected, setSelected] = useState<Address | undefined>();
  const pool = mine.find((p) => p.pool === selected) ?? mine[0];

  if (active === false)
    return (
      <div className="notice warn" style={{ marginTop: 16 }}>
        This wallet is not an approved Pool Delegate. Delegate approval is a governance (Timelock) action that
        requires completed KYC. See DEPLOY.md, “Approve a delegate”.
      </div>
    );
  if (!mine.length) return <Empty>You are an approved delegate but do not run a pool yet. Pools are opened by governance.</Empty>;

  return (
    <div className="grid" style={{ marginTop: 16 }}>
      {mine.length > 1 && (
        <select value={pool.pool} onChange={(e) => setSelected(e.target.value as Address)} aria-label="Pool">
          {mine.map((p) => (
            <option key={p.pool} value={p.pool}>{p.name}</option>
          ))}
        </select>
      )}
      <div className="grid grid-4">
        <Stat label="Pool NAV" value={fmtUsd(pool.seniorAssets + pool.juniorAssets)} />
        <Stat label="Idle cash" value={fmtUsd(pool.cash)} />
        <Stat label="Outstanding" value={fmtUsd(pool.outstandingPrincipal)} sub={`${pool.activeLoans.toString()} loans`} />
        <Stat label="Utilization" value={fmtBps(pool.utilizationBps)} />
      </div>
      <div className="grid grid-2">
        <FirstLoss pool={pool.pool} flv={pool.firstLossVault} stake={pool.firstLossStake} required={pool.requiredFirstLoss} impaired={pool.impaired} />
        <Borrowers pool={pool.pool} />
      </div>
      <Submissions pool={pool.pool} advanceRateBps={pool.params.advanceRateBps} maxFeeBps={pool.params.maxFeeBps} />
      <Servicing pool={pool.pool} epochs={pool.epochRedemptions} epochEndsAt={pool.epochEndsAt} />
    </div>
  );
}

function FirstLoss({ pool, flv, stake, required, impaired }: { pool: Address; flv: Address; stake: bigint; required: bigint; impaired: boolean }) {
  const { address: me } = useAccount();
  const tx = useTx();
  const [amt, setAmt] = useState("");
  const value = parseUsd(amt);
  const { data: allowance } = useReadContract({ address: deployment!.asset, abi: erc20Abi, functionName: "allowance", args: [me!, flv] });
  const excess = stake > required ? stake - required : 0n;

  async function deposit() {
    if (!value) return;
    if ((allowance ?? 0n) < value) {
      if (!(await tx.send({ address: deployment!.asset, abi: erc20Abi, functionName: "approve", args: [flv, value] }, `Approve ${STABLE.symbol}`))) return;
    }
    if (await tx.send({ address: flv, abi: firstLossVaultAbi, functionName: "deposit", args: [value] }, "Deposit first-loss")) setAmt("");
  }
  return (
    <div className="card">
      <h2>First-loss stake</h2>
      <p className="small muted">
        Slashed before the Junior tranche on every default. Delegate fees accrue here. Withdrawals are blocked while a
        loan is past due and may not take the stake below the requirement.
      </p>
      <div className="row" style={{ marginBottom: 10 }}>
        <span className="badge">stake {fmtUsd(stake)}</span>
        <span className="badge">required {fmtUsd(required)}</span>
        <span className={`badge ${stake >= required ? "good" : "bad"}`}>{stake >= required ? "covered" : "under-covered"}</span>
      </div>
      <div className="row">
        <input inputMode="decimal" placeholder={STABLE.symbol} value={amt} onChange={(e) => setAmt(e.target.value.replace(/[^0-9.]/g, ""))} aria-label="First-loss amount" />
        <button className="btn sm" disabled={!value || tx.busy} onClick={deposit}>Deposit</button>
        <button
          className="btn sm secondary"
          disabled={!value || value > excess || impaired || tx.busy}
          onClick={() => tx.send({ address: flv, abi: firstLossVaultAbi, functionName: "withdraw", args: [value!, me!] }, "Withdraw first-loss")}
        >
          Withdraw (max {fmtUsd(excess)})
        </button>
      </div>
      <TxStatus state={tx.state} />
      <span hidden>{pool}</span>
    </div>
  );
}

function Borrowers({ pool }: { pool: Address }) {
  const tx = useTx();
  const [who, setWho] = useState("");
  const [limit, setLimit] = useState("");
  const lim = parseUsd(limit);
  return (
    <div className="card">
      <h2>Approve a borrower</h2>
      <p className="small muted">Borrowers must have KYC recorded in the Compliance Registry. Limits cap total outstanding advances.</p>
      <div className="field">
        <label htmlFor="b">Borrower address</label>
        <input id="b" value={who} onChange={(e) => setWho(e.target.value.trim())} placeholder="0x…" />
      </div>
      <div className="field">
        <label htmlFor="l">Credit limit ({STABLE.symbol})</label>
        <input id="l" inputMode="decimal" value={limit} onChange={(e) => setLimit(e.target.value.replace(/[^0-9.]/g, ""))} />
      </div>
      <div className="row">
        <button className="btn" disabled={!isAddress(who) || !lim || tx.busy} onClick={() => tx.send({ address: pool, abi: creditPoolAbi, functionName: "approveBorrower", args: [who as Address, lim!] }, "Approve borrower")}>
          Approve / update limit
        </button>
        <button className="btn danger" disabled={!isAddress(who) || tx.busy} onClick={() => tx.send({ address: pool, abi: creditPoolAbi, functionName: "revokeBorrower", args: [who as Address] }, "Revoke borrower")}>
          Revoke
        </button>
      </div>
      <TxStatus state={tx.state} />
    </div>
  );
}

function Submissions({ pool, advanceRateBps, maxFeeBps }: { pool: Address; advanceRateBps: number; maxFeeBps: number }) {
  const { invoices } = useRecentInvoices();
  const pending = invoices.filter((i) => i.status === 2 && i.owner?.toLowerCase() === pool.toLowerCase());
  return (
    <div className="card">
      <h2>Invoices awaiting underwriting</h2>
      {!pending.length ? (
        <Empty>No submitted invoices.</Empty>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr><th>#</th><th>Borrower</th><th>Face value</th><th>Due</th><th>Document</th><th>Advance / fee</th></tr>
            </thead>
            <tbody>
              {pending.map((inv) => (
                <SubmissionRow key={inv.id.toString()} pool={pool} inv={inv} advanceRateBps={advanceRateBps} maxFeeBps={maxFeeBps} />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function SubmissionRow({ pool, inv, advanceRateBps, maxFeeBps }: { pool: Address; inv: ReturnType<typeof useRecentInvoices>["invoices"][number]; advanceRateBps: number; maxFeeBps: number }) {
  const tx = useTx();
  const maxAdvance = (inv.faceValue * BigInt(advanceRateBps)) / 10_000n;
  const [adv, setAdv] = useState(() => (Number(maxAdvance) / 1e6).toString());
  const [fee, setFee] = useState("2.5");
  const [note, setNote] = useState("");
  const advance = parseUsd(adv);
  const feeBps = Math.round(Number(fee) * 100);
  return (
    <tr>
      <td className="mono">#{inv.id.toString()}</td>
      <td className="mono">{short(inv.borrower)}</td>
      <td>{fmtUsd(inv.faceValue)}</td>
      <td>{fmtDate(inv.dueDate)}</td>
      <td className="mono small" title={inv.docCID}>{inv.docCID.slice(0, 14)}…</td>
      <td>
        <div className="row">
          <input style={{ width: 110 }} inputMode="decimal" value={adv} onChange={(e) => setAdv(e.target.value.replace(/[^0-9.]/g, ""))} aria-label="Advance" />
          <input style={{ width: 64 }} inputMode="decimal" value={fee} onChange={(e) => setFee(e.target.value.replace(/[^0-9.]/g, ""))} aria-label="Fee percent" />
          <span className="small muted">% fee</span>
        </div>
        <input style={{ marginTop: 6, width: "100%" }} placeholder="Underwriting notes (hashed on-chain)" value={note} onChange={(e) => setNote(e.target.value)} />
        <div className="row" style={{ marginTop: 6 }}>
          <button
            className="btn sm"
            disabled={!advance || advance > maxAdvance || feeBps > maxFeeBps || !note || tx.busy}
            onClick={() =>
              tx.send(
                { address: pool, abi: creditPoolAbi, functionName: "fundInvoice", args: [inv.id, advance!, feeBps, keccak256(toBytes(note))] },
                "Fund invoice"
              )
            }
          >
            Approve & fund
          </button>
          <button className="btn sm danger" disabled={tx.busy} onClick={() => tx.send({ address: pool, abi: creditPoolAbi, functionName: "rejectInvoice", args: [inv.id] }, "Reject")}>
            Reject
          </button>
        </div>
        <div className="small muted">max advance {fmtUsd(maxAdvance)} · max fee {fmtBps(maxFeeBps)}</div>
        <TxStatus state={tx.state} />
      </td>
    </tr>
  );
}

function Servicing({ pool, epochs, epochEndsAt }: { pool: Address; epochs: Address; epochEndsAt: bigint }) {
  const tx = useTx();
  const { data: ids } = useReadContract({ address: pool, abi: creditPoolAbi, functionName: "activeLoans", args: [0n, 250n] });
  const { data: loans } = useReadContracts({
    contracts: (ids ?? []).flatMap((id) => [
      { address: pool, abi: creditPoolAbi, functionName: "getLoan", args: [id] } as const,
      { address: pool, abi: creditPoolAbi, functionName: "defaultableAt", args: [id] } as const,
    ]),
    query: { enabled: !!ids?.length },
  });
  const now = BigInt(Math.floor(Date.now() / 1000));
  const dm = deployment!.defaultManager;
  return (
    <div className="card">
      <div className="spread">
        <h2>Loan servicing</h2>
        <button className="btn sm secondary" disabled={now < epochEndsAt || tx.busy} onClick={() => tx.send({ address: epochs, abi: epochRedemptionsAbi, functionName: "closeEpoch" }, "Close epoch")}>
          Close epoch {now < epochEndsAt ? `(${fmtDate(epochEndsAt)})` : ""}
        </button>
      </div>
      {!ids?.length ? (
        <Empty>No active loans.</Empty>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr><th>#</th><th>Borrower</th><th>Owed</th><th>Due</th><th>Status</th><th>Actions</th></tr>
            </thead>
            <tbody>
              {ids.map((id, i) => {
                const l = loans?.[i * 2]?.result as { borrower: Address; status: number; dueDate: bigint; principalOwed: bigint; feeOwed: bigint } | undefined;
                const at = loans?.[i * 2 + 1]?.result as bigint | undefined;
                if (!l) return null;
                const pastDue = l.dueDate < now;
                return (
                  <tr key={id.toString()}>
                    <td className="mono">#{id.toString()}</td>
                    <td className="mono">{short(l.borrower)}</td>
                    <td>{fmtUsd(l.principalOwed + l.feeOwed)}</td>
                    <td>{fmtDate(l.dueDate)}</td>
                    <td><span className={`badge ${pastDue ? "warn" : "good"}`}>{pastDue ? "Past due" : LOAN_STATUS[l.status]}</span></td>
                    <td className="row">
                      {pastDue && l.status === 2 && (
                        <button className="btn sm secondary" disabled={tx.busy} onClick={() => tx.send({ address: dm, abi: defaultManagerAbi, functionName: "markPastDue", args: [pool, id] }, "Mark past due")}>Mark late</button>
                      )}
                      {at !== undefined && now >= at ? (
                        <button className="btn sm danger" disabled={tx.busy} onClick={() => tx.send({ address: dm, abi: defaultManagerAbi, functionName: "triggerDefault", args: [pool, id] }, "Trigger default")}>Trigger default</button>
                      ) : (
                        <button className="btn sm danger" disabled={tx.busy} onClick={() => { if (confirm(`Declare invoice #${id} in default now? This writes off the principal immediately.`)) tx.send({ address: dm, abi: defaultManagerAbi, functionName: "declareDefault", args: [pool, id] }, "Declare default"); }}>Declare default</button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      <TxStatus state={tx.state} />
    </div>
  );
}
