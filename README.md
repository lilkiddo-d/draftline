# Draftline

On-chain private credit on **Robinhood Chain**. Vetted businesses borrow against invoices and receivables;
stablecoin (USDG) lenders fund them through **Senior** and **Junior** ERC-4626 tranches, protected by the pool
delegate's **first-loss stake** and, once $DRFT launches, a protocol-wide **staking backstop**.

> Status: deploy-ready, not audited. Read [THREAT_MODEL.md](THREAT_MODEL.md) before taking real money.

## How it works

1. **Governance** (48h Timelock) approves a KYC'd **Pool Delegate** and opens a pool for them.
2. The delegate posts a **first-loss stake**, then approves borrowers with credit limits.
3. Lenders deposit USDG into **Senior** (lower yield, paid first) or **Junior** (higher yield, absorbs losses
   after first-loss). Senior can never exceed the pool's subordination cap (default 80% of NAV).
4. A borrower mints an **InvoiceNFT** (face value, due date, hashed debtor reference and invoice number,
   encrypted document CID) and submits it to the pool; the NFT is escrowed.
5. The delegate verifies it off-chain and funds an advance (≤ advance rate × face value), committing a hash of
   the underwriting package on-chain. The invoice is now permanently marked financed.
6. On repayment the fee runs through the **income waterfall**: senior coupon → junior hurdle → protocol and
   delegate fees on the excess → junior. Principal returns to idle cash.
7. If unpaid: grace period → late fee → default window → **anyone** can trigger default. Losses hit
   **first-loss → Junior → Senior**; the $DRFT backstop then reimburses Senior. Recoveries restore Senior,
   then senior interest arrears, then Junior, then first-loss.
8. Lenders exit through **monthly epoch redemptions** from idle cash (Senior first). Redemptions, deposits and
   first-loss withdrawals freeze while any loan is past due, so nobody can front-run a known default.

## Repository

```
contracts/   Foundry project (Solidity 0.8.24, OpenZeppelin 5.6.1)
  src/pool/        CreditPool, Tranche, InvoiceNFT, FirstLossVault, EpochRedemptions, DefaultManager,
                   PoolFactory, PoolLens
  src/libraries/   Waterfall (income / loss / recovery priority), PoolParamsLib, Types
  src/compliance/  ComplianceRegistry (KYC + blocklist), Underwriting (delegate approvals)
  src/token/       FeeCollector, ProjectTokenHooks ($DRFT backstop; dormant until setProjectToken)
  src/oracle/      OracleAdapter (Chainlink / any AggregatorV3 source)
  src/governance/  Timelock (48h floor)
  script/          Deploy.s.sol, Governance.s.sol, DeployCore.sol, ChainConfig.sol, LocalDemo/LocalPin (local only)
  test/            unit, fuzz, invariant, fork (Robinhood Chain mainnet)
app/         Next.js 16 + wagmi/viem + RainbowKit frontend
scripts/     keeper.mjs (epochs, late/default, fees), local-chain.mjs (local mainnet-fork snapshot)
config/      chains.ts — chain ID, RPCs, explorer, verifier, USDG, Chainlink feeds, with sources
deployments/ <chainId>.json written by the deploy script
```

## Contracts at a glance

| Contract | Role |
|---|---|
| `PoolFactory` | Clones and initializes a pool's five contracts; pool registry; global pause; role registry for pools |
| `CreditPool` | Book-value accounting, invoice funding, repayment, write-off, recovery, deposit and redemption hooks |
| `Tranche` (×2) | ERC-4626 Senior/Junior shares; assets custodied by the pool; instant exits disabled |
| `InvoiceNFT` | One NFT per receivable; unique key, borrower ↔ pool transfers only, one-time financed latch |
| `Underwriting` | Delegate approvals (Timelock) and instant revocation (guardian) |
| `Waterfall` | Pure priority rules for income, losses and recoveries |
| `DefaultManager` | Late and default policy; permissionless triggers; calls the backstop safely |
| `FirstLossVault` | Delegate's first-loss stake; slashed before Junior |
| `EpochRedemptions` | Epoch exit queue with pro-rata partial fills |
| `OracleAdapter` | Staleness-checked prices for backstop sizing |
| `FeeCollector` | Splits protocol fees between treasury and $DRFT stakers |
| `ProjectTokenHooks` | Every $DRFT feature: set-once token, staking, rewards, Senior-loss slashing |
| `ComplianceRegistry` | KYC (borrowers and delegates on, lenders off by default) and sanctions blocklist |
| `Timelock` | Owns every admin role; ≥48h delay; guardian may cancel |
| `PoolLens` | Read-only summaries for the app and keeper |

## Verified

- **136 Foundry tests passing**: unit, fuzz (512 runs), 7 invariants (128 runs × depth 64) and 3 fork tests against Robinhood Chain mainnet using real USDG and the real Chainlink USDG/USD feed. Required properties are tested explicitly: losses hit first-loss → Junior → Senior; Junior is never paid before senior interest is current; an invoice can be financed only once.
- **Coverage**: 99.4% lines overall; every contract under `src/pool`, `src/token`, `src/compliance`, `src/oracle` and `src/libraries` ≥ 95%.
- **Slither**: 0 high, 0 medium.
- **Deploy**: full deploy and admin hand-off on a local fork of mainnet; mainnet dry run (~30.2M gas, ~0.0013 ETH).
- **Frontend**: production build passes; lender deposit, delegate funding and borrower repayment were exercised in a browser against the local fork.

## Quick start

```bash
pnpm install
cd contracts && forge build && forge test              # includes mainnet fork tests (public RPC)
```

Local end to end (forks mainnet, deploys, seeds a demo pool, serves on :8546):

```bash
node scripts/local-chain.mjs --fresh
```

Then in another terminal: set `NEXT_PUBLIC_CHAIN_ID=31337` in `app/.env.local` and run
`pnpm --filter @draftline/app build && pnpm --filter @draftline/app start`.

**Deploying to mainnet:** follow [DEPLOY.md](DEPLOY.md).

## Docs

- [DEPLOY.md](DEPLOY.md): exact deploy, governance, keeper and Vercel steps
- [DECISIONS.md](DECISIONS.md): every design decision with its reason
- [THREAT_MODEL.md](THREAT_MODEL.md): actors, top risks, controls, residual risk
- [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md): how $DRFT plugs in, and why nothing breaks without it
- Risk disclosure: `/risk` in the app

## Branding

Draftline is independent and is not affiliated with, endorsed by or sponsored by Robinhood. "Robinhood Chain"
appears only as the factual name of the network the contracts run on.
