#!/usr/bin/env node
/**
 * Local Robinhood Chain fork for development (chain id 31337, http://127.0.0.1:8546).
 *
 * Why not a plain `anvil --fork-url`? The public Robinhood Chain RPC is not an archive node and the chain
 * produces ~10 blocks/s, so a fork's pinned block is pruned within minutes and every later lookup of a new
 * account fails. This script therefore:
 *   1. compiles contracts,
 *   2. forks mainnet on a temporary port and immediately runs script/Deploy.s.sol + script/LocalDemo.s.sol
 *      (real USDG, real Chainlink USDG/USD feed, real Multicall3),
 *   3. pins every read-only mainnet dependency into local state (script/LocalPin.s.sol), dumps it, and (mainnet state touched + Draftline deployment) and
 *   4. serves it from a long-lived, non-forking anvil on :8546 with --auto-impersonate.
 * With an archive RPC (e.g. Alchemy) set as ROBINHOOD_RPC_URL you can also fork directly; see DEPLOY.md.
 *
 * Usage:  node scripts/local-chain.mjs           (reuse .local/fork-state.hex if present)
 *         node scripts/local-chain.mjs --fresh   (re-fork mainnet and redeploy)
 * Env:    ROBINHOOD_RPC_URL (default public RPC), DEMO_WALLET (your wallet to KYC + fund locally)
 * No private keys are used: all transactions are sent unsigned to anvil, which impersonates senders.
 */
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const contracts = join(root, "contracts");
const stateFile = join(root, ".local", "fork-state.hex");
const RPC = process.env.ROBINHOOD_RPC_URL || "https://rpc.mainnet.chain.robinhood.com";
const TEMP_PORT = 8547;
const PORT = 8546;
const DEPLOYER = "0xD3A1000000000000000000000000000000000001"; // local-only impersonated deployer
const fresh = process.argv.includes("--fresh") || !existsSync(stateFile);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function rpc(port, method, params = [], attempts = 5) {
  for (let i = 1; ; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      });
      const j = await res.json();
      if (j.error) throw new Error(`${method}: ${j.error.message}`);
      return j.result;
    } catch (e) {
      if (i >= attempts || String(e.message).startsWith(method)) throw e;
      await sleep(500 * i);
    }
  }
}

async function waitFor(port) {
  for (let i = 0; i < 120; i++) {
    try {
      await rpc(port, "eth_chainId");
      return;
    } catch {
      await sleep(500);
    }
  }
  throw new Error(`anvil on :${port} did not start`);
}

function run(cmd, args, cwd = contracts) {
  console.log(`$ ${cmd} ${args.join(" ")}`);
  const r = spawnSync(cmd, args, { cwd, stdio: "inherit", shell: process.platform === "win32" });
  if (r.status !== 0) throw new Error(`${cmd} failed with ${r.status}`);
}

async function buildSnapshot() {
  run("forge", ["build"]);
  const fork = spawn(
    "anvil",
    ["--fork-url", RPC, "--chain-id", "31337", "--auto-impersonate", "--port", String(TEMP_PORT), "--silent"],
    { stdio: "ignore" }
  );
  try {
    await waitFor(TEMP_PORT);
    const started = Date.now();
    await rpc(TEMP_PORT, "anvil_setBalance", [DEPLOYER, "0x56BC75E2D63100000"]);
    await rpc(TEMP_PORT, "evm_mine");
    const url = `http://127.0.0.1:${TEMP_PORT}`;
    run("forge", ["script", "script/Deploy.s.sol", "--rpc-url", url, "--unlocked", "--sender", DEPLOYER, "--broadcast"]);
    run("forge", ["script", "script/LocalDemo.s.sol", "--rpc-url", url, "--unlocked", "--sender", DEPLOYER, "--broadcast"]);
    // Make read-only mainnet state (USDG implementation, Chainlink aggregator, Multicall3) part of the dump.
    run("forge", ["script", "script/LocalPin.s.sol", "--rpc-url", url, "--sender", DEPLOYER]);
    console.log(`fork deploy + demo finished in ${Math.round((Date.now() - started) / 1000)}s`);
    const state = await rpc(TEMP_PORT, "anvil_dumpState");
    mkdirSync(dirname(stateFile), { recursive: true });
    writeFileSync(stateFile, state);
    console.log(`saved snapshot -> ${stateFile}`);
  } finally {
    fork.kill();
  }
}

async function serve() {
  const node = spawn(
    "anvil",
    ["--chain-id", "31337", "--auto-impersonate", "--port", String(PORT), "--block-time", "1", "--silent"],
    { stdio: "inherit" }
  );
  node.on("exit", (code) => {
    console.error(`anvil exited (${code}). Is port ${PORT} already in use?`);
    process.exit(1);
  });
  await waitFor(PORT);
  await rpc(PORT, "anvil_loadState", [readFileSync(stateFile, "utf8").trim()]);
  console.log(`\nDraftline local chain ready: http://127.0.0.1:${PORT} (chain id 31337). Ctrl+C to stop.`);
  const stop = () => {
    node.kill();
    process.exit(0);
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  await new Promise(() => {});
}

if (fresh) await buildSnapshot();
await serve();
