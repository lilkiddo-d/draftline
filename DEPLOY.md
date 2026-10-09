# Deploying Draftline to Robinhood Chain mainnet

Everything below is exactly what you run. Commands are for Git Bash / macOS / Linux shells; run them from the
repo root unless a step says `cd contracts`. Nothing in this repo ever asks for, stores or prints a private key:
signing happens only inside Foundry's encrypted keystore.

| | |
|---|---|
| Chain | Robinhood Chain mainnet, chain id **4663** |
| RPC | `https://rpc.mainnet.chain.robinhood.com` (public, rate-limited — fine for the deploy) |
| Explorer / verifier | Blockscout — `https://robinhoodchain.blockscout.com/api/` |
| Gas token | ETH. The full deploy simulated at ~30.2M gas ≈ **0.0013 ETH**; fund the deployer with **0.01 ETH** |
| Pool asset | USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Price feed | Chainlink USDG/USD `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` |

Sources for every address: [`config/chains.ts`](config/chains.ts).

## 0. Prerequisites (once)

- Foundry (`forge`, `cast`) ≥ 1.8, Node ≥ 20, pnpm ≥ 9.
- `pnpm install` at the repo root.
- Decide three addresses **before** deploying (they are baked in; changing them later needs the Timelock):
  - `TIMELOCK_PROPOSER` — who can queue governance actions. **Use a Safe multisig.**
  - `GUARDIAN` — can pause, revoke a delegate instantly, and cancel queued Timelock operations. A separate Safe or a hardware wallet.
  - `COMPLIANCE_OFFICER` — writes KYC status. The wallet of whoever runs KYC.
  - Optional: `TREASURY` (fee recipient, default = Timelock) and `BACKSTOP_LIQUIDATOR` (receives slashed $DRFT, default = treasury).
  If you leave them unset they all default to the deployer address — acceptable for a rehearsal, not for production.

## 1. Import the deployer key into Foundry's keystore

```bash
cast wallet import draftline-deployer --interactive
```

You paste the key and choose a password inside Foundry's prompt; it is stored encrypted in
`~/.foundry/keystores/draftline-deployer`. Print the address and fund it with ~0.01 ETH on Robinhood Chain:

```bash
cast wallet address --account draftline-deployer
```

## 2. Deploy + verify (one command)

```bash
cd contracts
export TIMELOCK_PROPOSER=0xYourSafe GUARDIAN=0xYourGuardian COMPLIANCE_OFFICER=0xYourKycWallet
forge script script/Deploy.s.sol --rpc-url robinhood --account draftline-deployer --sender $(cast wallet address --account draftline-deployer) --broadcast --slow --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

Optional rehearsal first (same command without `--broadcast --verify …`; writes only `deployments/dryrun-4663.json`):

```bash
forge script script/Deploy.s.sol --rpc-url robinhood --sender $(cast wallet address --account draftline-deployer)
```

What the script does: deploys the Timelock (48h), ComplianceRegistry, Underwriting, InvoiceNFT, OracleAdapter
(wired to the Chainlink USDG/USD feed), FeeCollector, ProjectTokenHooks, DefaultManager, the four clone
implementations, PoolFactory and PoolLens; wires them together; allow-lists USDG; grants `DEFAULT_ADMIN_ROLE`
on every contract to the Timelock and **renounces the deployer's** (it asserts this). It creates **no pools**.

Outputs (commit both):
- `deployments/4663.json` — every address + deploy block.
- `app/src/generated/deployment.4663.json` — the frontend reads this.

If verification of a contract times out, re-run just verification:

```bash
forge script script/Deploy.s.sol --rpc-url robinhood --account draftline-deployer --sender $(cast wallet address --account draftline-deployer) --resume --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

## 3. Activate $DRFT later: `setProjectToken`

Only after the token exists on Robinhood Chain. Two steps, ≥48h apart. Scheduling must be signed by the
`TIMELOCK_PROPOSER`: if that is an EOA, import it (`cast wallet import draftline-proposer --interactive`) and
`export PROPOSER_ACCOUNT=draftline-proposer` (or `PROPOSER_ACCOUNT=draftline-deployer` if you left the proposer
as the deployer). If it is a Safe, run the schedule step **without** `--broadcast`/`--account` and paste the
printed Timelock address, target, calldata and salt into the Safe Transaction Builder as a call to
`Timelock.schedule(target, 0, calldata, 0x00…00, salt, 172800)`. Execution can be sent by any account.

```bash
cd contracts
# 3a. schedule
forge script script/Governance.s.sol --sig "setProjectToken(address,bool)" 0xDRFT false --rpc-url robinhood --account $PROPOSER_ACCOUNT --sender $(cast wallet address --account $PROPOSER_ACCOUNT) --broadcast
# 3b. after 48h: execute (any account may execute)
forge script script/Governance.s.sol --sig "setProjectToken(address,bool)" 0xDRFT true --rpc-url robinhood --account draftline-deployer --sender $(cast wallet address --account draftline-deployer) --broadcast
```

The backstop also needs a $DRFT/USD price source to size slashing (see TOKEN_INTEGRATION.md); queue it the
same way with `--sig "setOracleFeed(address,address,uint32,bool)" 0xDRFT 0xFeed 86400 false` then `… true`.
Then set `NEXT_PUBLIC_PROJECT_TOKEN=0xDRFT` in Vercel and redeploy the app. `setProjectToken` can be called
exactly once, ever.

## 4. Approve a delegate and open the first pool

No pool exists until you do this. Order matters (Underwriting rejects delegates without KYC):

```bash
# 4a. KYC (compliance officer signs; expiry is a unix timestamp)
cast send <complianceRegistry> "setKyc(address,uint64)" 0xDelegate 1830297600 --rpc-url robinhood --account <compliance-officer-keystore>
# 4b. queue delegate approval, then 4c. execute after 48h
cd contracts
forge script script/Governance.s.sol --sig "approveDelegate(address,string,bool)" 0xDelegate "ipfs://<delegate-profile>" false --rpc-url robinhood --account $PROPOSER_ACCOUNT --sender $(cast wallet address --account $PROPOSER_ACCOUNT) --broadcast
forge script script/Governance.s.sol --sig "approveDelegate(address,string,bool)" 0xDelegate "ipfs://<delegate-profile>" true  --rpc-url robinhood --account draftline-deployer --sender $(cast wallet address --account draftline-deployer) --broadcast
# 4d. queue the pool, then 4e. execute after 48h (defaults in Governance.defaultParams: 80% advance,
#     20% junior floor, 8% senior / 14% junior hurdle, $2M cap, $50k minimum first-loss)
forge script script/Governance.s.sol --sig "createPool(address,string,string,bool)" 0xDelegate "Acme Receivables I" "ACME1" false --rpc-url robinhood --account $PROPOSER_ACCOUNT --sender $(cast wallet address --account $PROPOSER_ACCOUNT) --broadcast
forge script script/Governance.s.sol --sig "createPool(address,string,string,bool)" 0xDelegate "Acme Receivables I" "ACME1" true  --rpc-url robinhood --account draftline-deployer --sender $(cast wallet address --account draftline-deployer) --broadcast
```

You can queue 4b and 4d together only if 4b executes first (createPool checks the delegate is active); the
simplest is to queue 4d right after executing 4b. Afterwards the delegate, in the app's Delegate page:
deposits the first-loss stake (≥ $50k and ≥ 5% of outstanding), approves borrowers (who must be KYC'd by the
compliance officer), and funds invoices.

Guardian emergency actions (no delay): `PoolFactory.pause()` (every pool), `CreditPool.pause()` (one pool),
`Underwriting.revokeDelegate(addr)`, `Timelock.cancel(id)`. Unpausing requires the Timelock.

## 5. Start the keeper

The keeper only calls permissionless functions (mark past due, trigger defaults, close epochs, distribute
fees), so its key holds no power beyond its own gas.

```bash
cast wallet import draftline-keeper --interactive
cast wallet address --account draftline-keeper      # fund with ~0.005 ETH
CHAIN_ID=4663 pnpm keeper
```

For unattended operation put the keystore password in a file readable only by the service user and run e.g.
`ETH_PASSWORD_FILE=/etc/draftline/keeper.pw CHAIN_ID=4663 RPC_URL=<dedicated-rpc> pnpm keeper` under systemd
or pm2. `DRY_RUN=1` logs what it would send. `pnpm --filter @draftline/keeper once` runs a single pass.

## 6. Deploy the app to Vercel

1. Import the repo in Vercel. **Root Directory: `app`**. Framework: Next.js (auto). Vercel detects the pnpm
   workspace and installs from the root.
2. Environment variables (Production):
   - `NEXT_PUBLIC_CHAIN_ID=4663`
   - `NEXT_PUBLIC_RPC_URL=` a dedicated Robinhood Chain RPC (e.g. Alchemy) — recommended
   - `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=` from cloud.reown.com (optional; without it only injected wallets)
   - `NEXT_PUBLIC_PROJECT_TOKEN=` empty until $DRFT is activated on-chain
   - `NEXT_PUBLIC_GEOBLOCK_COUNTRIES=` e.g. `US,KP,IR,CU,SY` — get legal advice; this is a UI control only
3. Make sure `app/src/generated/deployment.4663.json` from step 2 is committed, then deploy.

## Local rehearsal (optional)

```bash
node scripts/local-chain.mjs --fresh                  # fork mainnet, deploy, seed a demo pool, serve on :8546
cp app/.env.example app/.env.local                    # then set NEXT_PUBLIC_CHAIN_ID=31337
pnpm --filter @draftline/app build && pnpm --filter @draftline/app start
```

The app then offers "Local dev: delegate / borrower / lender" wallets that send unsigned transactions to anvil
(no keys). The public RPC is not an archive node, so the script snapshots the fork instead of keeping a live
fork (see DECISIONS.md). `CHAIN_ID=31337 KEEPER_UNLOCKED=0xD3A1000000000000000000000000000000000001 pnpm keeper`
runs the keeper against it.
