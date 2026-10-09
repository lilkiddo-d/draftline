#!/usr/bin/env node
/**
 * Draftline keeper. Every action it takes is permissionless on-chain, so the keeper holds no protocol role:
 * a compromised keeper key can only waste its own gas.
 *
 *   - marks loans past due        DefaultManager.markPastDue      (due date passed)
 *   - triggers time-based defaults DefaultManager.triggerDefault  (due + grace + default window passed)
 *   - closes elapsed epochs        EpochRedemptions.closeEpoch     (epoch over, pool active, not impaired)
 *   - distributes protocol fees    FeeCollector.distribute(asset)  (once per FEE_INTERVAL)
 *
 * Reads use viem. Writes are signed by Foundry (`cast send --account draftline-keeper`) so the key never
 * leaves the encrypted keystore. For unattended runs set ETH_PASSWORD_FILE to a file containing the keystore
 * password (Foundry reads it; this script never does).
 *
 * Env:
 *   CHAIN_ID            4663 (default) or 31337 for the local fork
 *   RPC_URL             default: chain public RPC (use a dedicated RPC in production)
 *   KEEPER_ACCOUNT      Foundry keystore name (default draftline-keeper)
 *   KEEPER_UNLOCKED     local fork only: address to send from via anvil impersonation (no keystore)
 *   ETH_PASSWORD_FILE   optional keystore password file passed to cast as --password-file
 *   INTERVAL_SECONDS    loop period (default 300)
 *   FEE_INTERVAL_SECONDS fee distribution period (default 86400)
 *   DRY_RUN=1           log intended transactions without sending
 * Flags: --once  run a single pass and exit
 */
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, parseAbi } from "viem";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const CHAIN_ID = Number(process.env.CHAIN_ID || 4663);
const RPC_URL =
  process.env.RPC_URL || (CHAIN_ID === 31337 ? "http://127.0.0.1:8546" : "https://rpc.mainnet.chain.robinhood.com");
const ACCOUNT = process.env.KEEPER_ACCOUNT || "draftline-keeper";
const UNLOCKED = process.env.KEEPER_UNLOCKED || "";
const INTERVAL = Number(process.env.INTERVAL_SECONDS || 300) * 1000;
const FEE_INTERVAL = Number(process.env.FEE_INTERVAL_SECONDS || 86_400) * 1000;
const DRY_RUN = process.env.DRY_RUN === "1";
const ONCE = process.argv.includes("--once");

if (UNLOCKED && CHAIN_ID !== 31337) {
  console.error("KEEPER_UNLOCKED is only allowed on the local fork (CHAIN_ID=31337).");
  process.exit(1);
}

const d = JSON.parse(readFileSync(join(root, "deployments", `${CHAIN_ID}.json`), "utf8"));
const client = createPublicClient({ transport: http(RPC_URL) });

const factoryAbi = parseAbi([
  "function poolCount() view returns (uint256)",
  "function getPools(uint256 offset, uint256 limit) view returns (address[])",
]);
const lensAbi = parseAbi(["function keeperWork(address pool) view returns (uint256[] markable, uint256[] defaultable)"]);
const poolAbi = parseAbi([
  "function epochRedemptions() view returns (address)",
  "function isActive() view returns (bool)",
  "function isImpaired() view returns (bool)",
]);
const epochAbi = parseAbi(["function epochEndsAt() view returns (uint256)"]);
const erc20Abi = parseAbi(["function balanceOf(address) view returns (uint256)"]);

const log = (...a) => console.log(new Date().toISOString(), ...a);

function send(to, sig, args = []) {
  const cmd = ["send", to, sig, ...args.map(String), "--rpc-url", RPC_URL];
  if (UNLOCKED) cmd.push("--unlocked", "--from", UNLOCKED);
  else {
    cmd.push("--account", ACCOUNT);
    if (process.env.ETH_PASSWORD_FILE) cmd.push("--password-file", process.env.ETH_PASSWORD_FILE);
  }
  log(`${DRY_RUN ? "[dry-run] " : ""}cast ${sig} ${args.join(" ")} -> ${to}`);
  if (DRY_RUN) return true;
  const r = spawnSync("cast", cmd, { stdio: ["inherit", "pipe", "pipe"], encoding: "utf8" });
  if (r.status !== 0) {
    log(`  failed: ${(r.stderr || r.stdout || "").trim().split("\n").slice(-1)[0]}`);
    return false;
  }
  const status = /status\s+(\d)/.exec(r.stdout)?.[1];
  log(`  ${status === "1" ? "ok" : "reverted"} ${/transactionHash\s+(\S+)/.exec(r.stdout)?.[1] ?? ""}`);
  return status === "1";
}

async function pools() {
  const n = await client.readContract({ address: d.poolFactory, abi: factoryAbi, functionName: "poolCount" });
  const out = [];
  for (let i = 0n; i < n; i += 100n) {
    out.push(...(await client.readContract({ address: d.poolFactory, abi: factoryAbi, functionName: "getPools", args: [i, 100n] })));
  }
  return out;
}

let lastFees = 0;

async function pass() {
  const now = BigInt(Math.floor(Date.now() / 1000));
  const block = await client.getBlock();
  const chainNow = block.timestamp > now ? block.timestamp : now;
  for (const pool of await pools()) {
    try {
      const [markable, defaultable] = await client.readContract({ address: d.poolLens, abi: lensAbi, functionName: "keeperWork", args: [pool] });
      for (const id of markable) send(d.defaultManager, "markPastDue(address,uint256)", [pool, id]);
      for (const id of defaultable) send(d.defaultManager, "triggerDefault(address,uint256)", [pool, id]);

      const epochs = await client.readContract({ address: pool, abi: poolAbi, functionName: "epochRedemptions" });
      const [endsAt, active, impaired] = await Promise.all([
        client.readContract({ address: epochs, abi: epochAbi, functionName: "epochEndsAt" }),
        client.readContract({ address: pool, abi: poolAbi, functionName: "isActive" }),
        client.readContract({ address: pool, abi: poolAbi, functionName: "isImpaired" }),
      ]);
      if (chainNow >= endsAt) {
        if (!active) log(`pool ${pool}: epoch due but pool is paused`);
        else if (impaired) log(`pool ${pool}: epoch due but a loan is past due; waiting for repayment or default`);
        else send(epochs, "closeEpoch()");
      }
    } catch (e) {
      log(`pool ${pool}: ${e.shortMessage || e.message}`);
    }
  }
  if (Date.now() - lastFees >= FEE_INTERVAL) {
    const bal = await client.readContract({ address: d.asset, abi: erc20Abi, functionName: "balanceOf", args: [d.feeCollector] });
    if (bal > 0n) send(d.feeCollector, "distribute(address)", [d.asset]);
    lastFees = Date.now();
  }
}

log(`Draftline keeper on chain ${CHAIN_ID} via ${RPC_URL} as ${UNLOCKED || `keystore:${ACCOUNT}`}${DRY_RUN ? " (dry run)" : ""}`);
do {
  try {
    await pass();
  } catch (e) {
    log(`pass failed: ${e.shortMessage || e.message}`);
  }
  if (!ONCE) await new Promise((r) => setTimeout(r, INTERVAL));
} while (!ONCE);
