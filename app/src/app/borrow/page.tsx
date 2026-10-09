"use client";

import { useMemo, useState } from "react";
import { erc20Abi, keccak256, toBytes, type Address } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { Empty, RequireWallet, TxStatus, useTx } from "@/components/ui";
import { complianceRegistryAbi, creditPoolAbi, invoiceNFTAbi, poolLensAbi } from "@/generated/abis";
import { STABLE } from "@/lib/chain";
import { deployment } from "@/lib/deployments";
import { fmtDate, fmtUsd, INVOICE_STATUS, parseUsd, short } from "@/lib/format";
import { usePoolSummaries, useRecentInvoices, type RecentInvoice } from "@/lib/hooks";

export default function BorrowPage() {
  return (
    <>
      <h1>Borrower portal</h1>
      <p className="muted">
        Tokenize an invoice, submit it to a pool you are approved for, and receive an advance in {STABLE.symbol} once
        the pool delegate verifies it. Repay principal plus fee when your customer pays.
      </p>
      {!deployment ? <Empty>Draftline is not deployed on this network yet.</Empty> : <RequireWallet><Portal /></RequireWallet>}
    </>
  );
}

function Portal() {
  const { address: me } = useAccount();
  const { data: canBorrow } = useReadContract({
    address: deployment!.complianceRegistry,
    abi: complianceRegistryAbi,
    functionName: "canBorrow",
    args: [me!],
  });
  const { data: pools } = usePoolSummaries();
  const { data: approvals } = useReadContracts({
    contracts: (pools ?? []).map((p) => ({ address: p.pool, abi: creditPoolAbi, functionName: "approvedBorrower", args: [me!] }) as const),
    query: { enabled: !!pools?.length },
  });
  const myPools = (pools ?? []).filter((_, i) => approvals?.[i]?.result === true);
  const { invoices } = useRecentInvoices();
  const mine = invoices.filter((i) => i.borrower.toLowerCase() === me!.toLowerCase());

  return (
    <div className="grid" style={{ marginTop: 16 }}>
      {canBorrow === false && (
        <div className="notice warn">
          This wallet has not completed borrower KYC. Contact a pool delegate to start onboarding; you cannot mint
          invoices until your KYC is recorded on-chain.
        </div>
      )}
      <div className="grid grid-2">
        <MintForm disabled={canBorrow !== true} />
        <div className="card">
          <h2>Your pools</h2>
          {!myPools.length ? (
            <Empty>You are not approved in any pool yet. Delegates approve borrowers after underwriting.</Empty>
          ) : (
            <table>
              <tbody>
                {myPools.map((p) => (
                  <BorrowerPoolRow key={p.pool} pool={p.pool} name={p.name} />
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
      <div className="card">
        <h2>Your invoices</h2>
        {!mine.length ? (
          <Empty>No invoices yet.</Empty>
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr><th>#</th><th>Face value</th><th>Due</th><th>Status</th><th>Holder</th><th>Action</th></tr>
              </thead>
              <tbody>
                {mine.map((inv) => (
                  <InvoiceRow key={inv.id.toString()} inv={inv} pools={myPools.map((p) => ({ pool: p.pool, name: p.name }))} />
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}

function BorrowerPoolRow({ pool, name }: { pool: Address; name: string }) {
  const { address: me } = useAccount();
  const { data } = useReadContracts({
    contracts: [
      { address: pool, abi: creditPoolAbi, functionName: "borrowerLimit", args: [me!] },
      { address: pool, abi: creditPoolAbi, functionName: "borrowerOutstanding", args: [me!] },
    ],
  });
  return (
    <tr>
      <td>{name}</td>
      <td className="small">
        {fmtUsd(data?.[1]?.result as bigint | undefined)} drawn of {fmtUsd(data?.[0]?.result as bigint | undefined)} limit
      </td>
    </tr>
  );
}

function MintForm({ disabled }: { disabled: boolean }) {
  const tx = useTx();
  const [face, setFace] = useState("");
  const [due, setDue] = useState("");
  const [debtor, setDebtor] = useState("");
  const [number, setNumber] = useState("");
  const [cid, setCid] = useState("");
  const faceValue = parseUsd(face);
  const dueTs = due ? BigInt(Math.floor(new Date(`${due}T23:59:59Z`).getTime() / 1000)) : 0n;
  // Both hashes are deterministic over normalized input so the same receivable always maps to the same
  // on-chain key (InvoiceNFT rejects duplicates forever). Only hashes go on-chain, never names or numbers.
  const debtorRefHash = useMemo(() => (debtor.trim() ? keccak256(toBytes(`draftline:debtor:${normalize(debtor)}`)) : undefined), [debtor]);
  const invoiceNumberHash = useMemo(
    () => (number.trim() ? keccak256(toBytes(`draftline:invoice:${normalize(number)}`)) : undefined),
    [number]
  );
  const ok = faceValue && dueTs > BigInt(Math.floor(Date.now() / 1000)) && debtorRefHash && invoiceNumberHash && cid.trim().length > 0;

  async function mint() {
    if (!ok) return;
    const sent = await tx.send(
      {
        address: deployment!.invoiceNFT,
        abi: invoiceNFTAbi,
        functionName: "mint",
        args: [faceValue!, dueTs, debtorRefHash!, invoiceNumberHash!, cid.trim()],
      },
      "Mint invoice"
    );
    if (sent) {
      setFace("");
      setDue("");
      setNumber("");
      setCid("");
    }
  }

  return (
    <div className="card">
      <h2>Tokenize an invoice</h2>
      <div className="field">
        <label htmlFor="face">Face value ({STABLE.symbol})</label>
        <input id="face" inputMode="decimal" value={face} onChange={(e) => setFace(e.target.value.replace(/[^0-9.]/g, ""))} />
      </div>
      <div className="field">
        <label htmlFor="due">Due date</label>
        <input id="due" type="date" value={due} onChange={(e) => setDue(e.target.value)} />
      </div>
      <div className="field">
        <label htmlFor="debtor">Debtor reference (e.g. customer registration number, kept off-chain)</label>
        <input id="debtor" value={debtor} onChange={(e) => setDebtor(e.target.value)} />
      </div>
      <div className="field">
        <label htmlFor="num">Invoice number</label>
        <input id="num" value={number} onChange={(e) => setNumber(e.target.value)} />
      </div>
      <div className="field">
        <label htmlFor="cid">Encrypted document CID (IPFS)</label>
        <input id="cid" placeholder="bafy…" value={cid} onChange={(e) => setCid(e.target.value)} />
      </div>
      <p className="small muted">
        Encrypt the invoice PDF and supporting documents before pinning; share the key with the delegate off-chain.
        Each debtor + invoice number can be tokenized only once, ever.
      </p>
      <button className="btn" disabled={disabled || !ok || tx.busy} onClick={mint}>
        Mint invoice NFT
      </button>
      <TxStatus state={tx.state} />
    </div>
  );
}

function InvoiceRow({ inv, pools }: { inv: RecentInvoice; pools: { pool: Address; name: string }[] }) {
  const tx = useTx();
  const [target, setTarget] = useState<Address | "">(pools[0]?.pool ?? "");
  const status = INVOICE_STATUS[inv.status];
  const holderIsPool = inv.owner && inv.owner.toLowerCase() !== inv.borrower.toLowerCase();
  const pool = holderIsPool ? (inv.owner as Address) : undefined;

  const { data: owed } = useReadContract({
    address: deployment!.poolLens,
    abi: poolLensAbi,
    functionName: "amountOwed",
    args: pool ? [pool, inv.id] : undefined,
    query: { enabled: !!pool && status === "Financed" },
  });
  const { address: me } = useAccount();
  const { data: allowance } = useReadContract({
    address: deployment!.asset,
    abi: erc20Abi,
    functionName: "allowance",
    args: pool && me ? [me, pool] : undefined,
    query: { enabled: !!pool && status === "Financed" },
  });

  async function submit() {
    if (!target) return;
    const a = await tx.send({ address: deployment!.invoiceNFT, abi: invoiceNFTAbi, functionName: "approve", args: [target, inv.id] }, "Approve invoice");
    if (a) await tx.send({ address: target, abi: creditPoolAbi, functionName: "submitInvoice", args: [inv.id] }, "Submit to pool");
  }

  async function repay() {
    if (!pool || !owed) return;
    // Small buffer for the fee accrued between read and inclusion is unnecessary: fees are fixed per loan.
    if ((allowance ?? 0n) < owed) {
      const a = await tx.send({ address: deployment!.asset, abi: erc20Abi, functionName: "approve", args: [pool, owed] }, `Approve ${STABLE.symbol}`);
      if (!a) return;
    }
    await tx.send({ address: pool, abi: creditPoolAbi, functionName: "repay", args: [inv.id, owed] }, "Repay");
  }

  return (
    <tr>
      <td className="mono">#{inv.id.toString()}</td>
      <td>{fmtUsd(inv.faceValue)}</td>
      <td>{fmtDate(inv.dueDate)}</td>
      <td><span className={`badge ${status === "Defaulted" ? "bad" : status === "Financed" ? "good" : ""}`}>{status}</span></td>
      <td className="mono small">{holderIsPool ? `pool ${short(inv.owner)}` : "you"}</td>
      <td>
        {status === "Minted" && (
          <div className="row">
            <select value={target} onChange={(e) => setTarget(e.target.value as Address)} aria-label="Pool">
              {pools.map((p) => (
                <option key={p.pool} value={p.pool}>{p.name}</option>
              ))}
            </select>
            <button className="btn sm" disabled={!target || tx.busy} onClick={submit}>Submit</button>
            <button className="btn sm secondary" disabled={tx.busy} onClick={() => tx.send({ address: deployment!.invoiceNFT, abi: invoiceNFTAbi, functionName: "cancel", args: [inv.id] }, "Cancel invoice")}>Cancel</button>
          </div>
        )}
        {status === "Submitted" && pool && (
          <button className="btn sm secondary" disabled={tx.busy} onClick={() => tx.send({ address: pool, abi: creditPoolAbi, functionName: "withdrawSubmission", args: [inv.id] }, "Withdraw")}>
            Withdraw
          </button>
        )}
        {status === "Financed" && (
          <button className="btn sm" disabled={!owed || tx.busy} onClick={repay}>
            Repay {fmtUsd(owed as bigint | undefined, 2)}
          </button>
        )}
        <TxStatus state={tx.state} />
      </td>
    </tr>
  );
}

/** Case-, whitespace- and punctuation-insensitive form so trivial variations map to the same hash. */
function normalize(s: string) {
  return s.normalize("NFKC").toLowerCase().replace(/[\s.,\-_/]+/g, "");
}
