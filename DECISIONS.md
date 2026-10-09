# Decisions

One line of reasoning per decision. Ordered roughly by when they were made.

## Chain and dependencies
- **Stablecoin = USDG** (`0x5fc5…d168`, 6 dec) — it is the only stablecoin listed on Robinhood Chain's official token-contracts page; verified on-chain (~$692M supply). USDC/USDT have Chainlink feeds there but no official token address, so they are not allow-listed.
- **Oracle = Chainlink** USDG/USD (`0x61B7…9aD2`) — Robinhood Chain docs name Chainlink the sole oracle provider; address from Chainlink's feed directory JSON and checked live.
- **Feed heartbeat set to 25h** (24h + 1h slack) — Chainlink publishes a 24h heartbeat; a tighter window would make the adapter reject healthy prices.
- **No sequencer-uptime check (gap)** — Chainlink publishes no L2 sequencer-uptime feed for Robinhood Chain; OracleAdapter supports one and governance can set it when it appears. Impact is limited because prices are only used for backstop sizing, which fails safe (skips) on bad data.
- **Verification via Blockscout** — the official deploy guide uses `--verifier blockscout`.
- **OpenZeppelin 5.6.1 via npm, forge-std via submodule** — pinned versions; OZ 5.6's `ReentrancyGuard` uses namespaced storage, so the same contract works in clones.
- **`evm_version = cancun`** — Robinhood Chain is an Arbitrum Orbit chain on a current ArbOS; the mainnet fork tests and dry run executed the bytecode successfully.

## Architecture
- **Pools are five EIP-1167 clones** (pool, senior, junior, first-loss vault, epoch queue) — cheap per-pool deploys, no proxy admin, and immutable logic (no upgrade key to steal).
- **Pools read roles from the PoolFactory** — one AccessControl registry for all pools (Timelock = admin, guardian = pause); it also saved ~0.5KB in CreditPool.
- **CreditPool custodies all cash; tranches hold none** — a single balance sheet makes the NAV identity (`senior + junior == cash + outstanding`) checkable and lets tranches be thin ERC-4626 wrappers.
- **Internal cash accounting** — token donations never change NAV (kills donation/inflation tricks); plus a 6-decimal ERC-4626 offset.
- **Book-value NAV, income on receipt** — no mark-to-model; the trade-off is a step drop at default, mitigated by the impairment freeze below.
- **Coupons accrue only on deployed capital** — accruing senior interest on idle cash would create unbounded arrears and starve junior forever.
- **Income waterfall: senior coupon → junior hurdle → protocol + delegate fee on the excess → junior residual** — implements "senior, then junior, then protocol fee" literally while keeping junior the higher-yield tranche.
- **Delegate fee is credited to the first-loss vault** — aligns the delegate: fees become more first-loss cover.
- **Recovery waterfall: senior write-down → senior interest arrears → junior write-down → first-loss → excess as income** — required so junior is never paid while senior interest is unpaid (an invariant test caught the earlier ordering).
- **Junior residual with zero junior holders goes to the protocol** — otherwise it would be stranded in an empty tranche and gifted to the next depositor.
- **Waterfall is an internal library** — pure, inlined, fuzzed directly; no external trust surface.
- **DefaultManager is global and not pausable** — loss recognition protects lenders and must always be available; timing-based defaults are permissionless.
- **Delegate or governance may declare an early default** — confirmed fraud must not wait out a 35-day window while lenders can't exit.
- **"Impaired" = any active loan past its due date (bounded loop, ≤250 loans)** — blocks deposits, epoch processing and first-loss withdrawals without relying on a keeper to flag it first.
- **Epoch exits: one request per user per tranche; unfilled shares returned, not rolled** — every operation O(1); rolling partial fills would require unbounded per-epoch loops.
- **Epoch close plans both fills as a view, records state, then executes** — strict checks-effects-interactions (resolved a Slither reentrancy finding).
- **Senior redeems first; junior only above the subordination floor** — senior priority in liquidity as well as losses.
- **`repay` and `recover` work while paused** — a pause must never push borrowers into late fees or block incoming cash.
- **FeeCollector distributes, ProjectTokenHooks holds every $DRFT feature** — one contract to activate, one place to audit token risk.
- **Backstop slashes $DRFT to a liquidator, which sells and calls `recover`** — there is no trustworthy on-chain $DRFT liquidity at launch; an async, governance-run sale is safer than an on-chain swap that could be sandwiched.
- **Backstop failure can never block a default** — `try/catch` in DefaultManager; the backstop returns 0 when the token, price or stake is missing.
- **PoolLens is a separate read-only contract** — keeps CreditPool under the 24KB limit and gives the frontend one-call summaries.
- **PoolParamsLib is an external library** — moves ~1KB out of CreditPool; it is pure, so linking adds no risk.
- **optimizer_runs = 10** — size headroom for CreditPool (~22.5KB of 24KB); gas is cheap on this L2.

## Governance and compliance
- **Timelock: 48h floor enforced in the constructor and in `updateDelay`** — governance cannot shorten its own delay.
- **Open executor, single proposer (Safe), guardian = canceller** — liveness (anyone executes ready ops) plus a veto against malicious proposals.
- **Guardian pauses; only the Timelock unpauses** — a compromised guardian can't undo a deliberate pause; worst case is a 48h outage.
- **Pool creation and delegate approval are both Timelock actions** — "no real pools until I approve a delegate" is enforced on-chain, not by convention.
- **Guardian can revoke a delegate instantly** — the main response to delegate collusion.
- **KYC defaults: borrowers ON, delegates ON, lenders OFF; blocklist always ON** — per the brief; the lender flag is one Timelock call.
- **KYC has an expiry** — periodic re-verification without extra transactions to revoke.
- **Keeper actions are all permissionless** — the keeper key has zero protocol power.

## Invoices
- **Uniqueness key = keccak(debtorRefHash, invoiceNumberHash), consumed forever** — even cancelled invoices can't be re-minted.
- **Frontend hashes debtor reference and invoice number deterministically (normalized, unsalted)** — salting per mint would let the same receivable produce a new key each time; the trade-off (low-entropy IDs can be brute-forced) is in THREAT_MODEL.md.
- **NFT can only move borrower ↔ registered pool** — it cannot be pledged to an outside market while escrowed or financed.
- **`financed` is a one-way latch** — a repaid invoice returns to the borrower as a record but can never be financed again.

## Tooling
- **Local fork is served from a state snapshot** — the public RPC is not archive and the chain makes ~10 blocks/s, so a live `anvil --fork-url` breaks within minutes. `scripts/local-chain.mjs` deploys during the fork window, pins every read-only mainnet dependency (`LocalPin.s.sol`), dumps state and serves it from a plain anvil.
- **Local-only mock wallet in the app** — lets the whole UI be exercised against anvil without any private key; it is disabled unless `NEXT_PUBLIC_CHAIN_ID=31337`.
- **Dry runs write `deployments/dryrun-<id>.json`** — a simulation can never overwrite a real deployment record or the frontend config.
- **Frontend reads on-chain enumerations, not event logs** — at ~10 blocks/s, log range queries on public RPCs are impractical.
- **Next 16 `proxy.ts` for geoblocking** — `middleware.ts` is deprecated in Next 16.
- **x402 packages are stubbed in the app build** — they are optional Coinbase CDP dependencies pulled in by wagmi's Base Account connector and never executed by Draftline.
- **wagmi 2.x** — RainbowKit 2.2 requires wagmi ^2.
