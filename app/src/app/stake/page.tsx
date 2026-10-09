"use client";

import { useState } from "react";
import { erc20Abi, formatUnits, maxUint256, parseUnits } from "viem";
import { useAccount, useReadContracts } from "wagmi";
import { Empty, RequireWallet, Stat, TxStatus, useTx } from "@/components/ui";
import { feeCollectorAbi, projectTokenHooksAbi } from "@/generated/abis";
import { PROJECT_TOKEN, STABLE, tokenFeaturesEnabled } from "@/lib/chain";
import { deployment } from "@/lib/deployments";
import { fmtBps, fmtDate, fmtUsd } from "@/lib/format";

export default function StakePage() {
  if (!tokenFeaturesEnabled) return <Empty>$DRFT features are not live yet.</Empty>;
  if (!deployment) return <Empty>Draftline is not deployed on this network yet.</Empty>;
  return (
    <>
      <h1>$DRFT backstop</h1>
      <p className="muted">
        Stakers form a protocol-wide backstop. If a default reaches the Senior tranche after first-loss and Junior are
        exhausted, up to the slash cap of staked $DRFT is sold to make Senior whole. In return stakers earn a share of
        protocol fees in {STABLE.symbol}. Unstaking requires a cooldown, during which your stake can still be slashed.
      </p>
      <RequireWallet>
        <Staking />
      </RequireWallet>
    </>
  );
}

function Staking() {
  const { address: me } = useAccount();
  const hooks = deployment!.projectTokenHooks;
  const token = PROJECT_TOKEN as `0x${string}`;
  const tx = useTx();
  const [amt, setAmt] = useState("");
  const { data } = useReadContracts({
    contracts: [
      { address: hooks, abi: projectTokenHooksAbi, functionName: "isActive" },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "projectToken" },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "totalStaked" },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "stakedBalance", args: [me!] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "earned", args: [me!] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "cooldowns", args: [me!] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "sharesOf", args: [me!] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "maxSlashBps" },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "cooldownPeriod" },
      { address: token, abi: erc20Abi, functionName: "balanceOf", args: [me!] },
      { address: token, abi: erc20Abi, functionName: "allowance", args: [me!, hooks] },
      { address: token, abi: erc20Abi, functionName: "decimals" },
      { address: deployment!.feeCollector, abi: feeCollectorAbi, functionName: "stakerShareBps" },
    ],
  });
  const r = (i: number) => data?.[i]?.result;
  const active = r(0) as boolean | undefined;
  const onChainToken = r(1) as string | undefined;
  const dec = (r(11) as number | undefined) ?? 18;
  const fmt = (v: unknown) => (typeof v === "bigint" ? Number(formatUnits(v, dec)).toLocaleString("en-US", { maximumFractionDigits: 2 }) : "—");
  const cooldown = r(5) as readonly [bigint, bigint] | undefined;
  const shares = (r(6) as bigint | undefined) ?? 0n;
  const wallet = (r(9) as bigint | undefined) ?? 0n;
  const allowance = (r(10) as bigint | undefined) ?? 0n;
  let value: bigint | undefined;
  try {
    value = amt ? parseUnits(amt as `${number}`, dec) : undefined;
  } catch {
    value = undefined;
  }
  const now = BigInt(Math.floor(Date.now() / 1000));

  if (active === false || (onChainToken && onChainToken.toLowerCase() !== token.toLowerCase())) {
    return (
      <div className="notice warn">
        The backstop has not been activated on-chain for this token yet (governance must call setProjectToken via the
        Timelock).
      </div>
    );
  }

  async function stake() {
    if (!value) return;
    if (allowance < value) {
      if (!(await tx.send({ address: token, abi: erc20Abi, functionName: "approve", args: [hooks, maxUint256] }, "Approve $DRFT"))) return;
    }
    if (await tx.send({ address: hooks, abi: projectTokenHooksAbi, functionName: "stake", args: [value] }, "Stake")) setAmt("");
  }

  return (
    <div className="grid">
      <div className="grid grid-4">
        <Stat label="Total staked" value={fmt(r(2))} />
        <Stat label="Your stake" value={fmt(r(3))} />
        <Stat label={`Earned (${STABLE.symbol})`} value={fmtUsd(r(4) as bigint | undefined, 2)} />
        <Stat label="Fee share / slash cap" value={`${fmtBps(r(12) as number | undefined)} / ${fmtBps(r(7) as number | undefined)}`} />
      </div>
      <div className="card">
        <div className="row">
          <input inputMode="decimal" placeholder="$DRFT amount" value={amt} onChange={(e) => setAmt(e.target.value.replace(/[^0-9.]/g, ""))} aria-label="Stake amount" />
          <button className="btn" disabled={!value || value > wallet || tx.busy} onClick={stake}>Stake</button>
          <button className="btn secondary" disabled={!shares || tx.busy} onClick={() => tx.send({ address: hooks, abi: projectTokenHooksAbi, functionName: "requestUnstake", args: [shares - (cooldown?.[0] ?? 0n)] }, "Start cooldown")}>
            Start cooldown ({Number(r(8) ?? 0n) / 86400}d)
          </button>
          <button className="btn secondary" disabled={!cooldown || cooldown[0] === 0n || now < cooldown[1] || tx.busy} onClick={() => tx.send({ address: hooks, abi: projectTokenHooksAbi, functionName: "unstake" }, "Unstake")}>
            Unstake{cooldown && cooldown[0] > 0n ? ` (unlocks ${fmtDate(cooldown[1])})` : ""}
          </button>
          <button className="btn secondary" disabled={tx.busy} onClick={() => tx.send({ address: hooks, abi: projectTokenHooksAbi, functionName: "claimRewards" }, "Claim rewards")}>
            Claim rewards
          </button>
        </div>
        <div className="small muted" style={{ marginTop: 6 }}>Wallet: {fmt(wallet)} $DRFT</div>
        <TxStatus state={tx.state} />
      </div>
    </div>
  );
}
