# Threat model

Scope: the contracts in `contracts/src`, the deploy and governance scripts, the keeper and the frontend.
Assets at risk: lender USDG in pools, delegate first-loss stakes, $DRFT stakes, protocol fees.

## Actors and trust

| Actor | Trusted for | Can | Cannot |
|---|---|---|---|
| Timelock (Safe proposer, 48h) | everything administrative | change params, approve delegates, create pools, replace delegates, unpause, set the project token once | act without 48h public notice; shorten its delay below 48h; move pool funds directly |
| Guardian | fast defensive actions | pause pools / factory / periphery, revoke delegates, cancel queued Timelock ops | unpause, move funds, change params |
| Compliance officer | KYC data | set KYC expiry and blocklist | touch funds or roles |
| Pool Delegate | underwriting quality | approve borrowers and limits, fund or reject invoices, declare early default, manage own first-loss | exceed advance rate, tenor, fee cap, concentration or borrower limits; fund without cover; withdraw cover while a loan is past due |
| Borrower | nothing | mint, submit, withdraw unfunded submissions, repay | move a pledged NFT, re-pledge an invoice, borrow without delegate approval |
| Lender | nothing | deposit, queue withdrawals, claim | exit instantly or at a stale NAV |
| Keeper | nothing (permissionless) | mark late, default, close epochs, distribute fees | anything privileged |

## Top risks (from the brief)

### 1. Fake or double-pledged invoices
**Attack:** a borrower tokenizes a fictitious invoice, or finances the same receivable twice (inside Draftline or with another lender).
**Controls:**
- `InvoiceNFT` uniqueness key `keccak(debtorRefHash, invoiceNumberHash)` is registered once, forever (cancel doesn't free it).
- The NFT can only move borrower ↔ registered pool; while submitted or financed it is escrowed in the pool.
- `financed` is a one-way latch; `fundInvoice` reverts if it is already set (invariant-tested: `invariant_financedOnce`, plus a handler that tries every route to re-finance).
- The delegate must verify the invoice off-chain (debtor confirmation, PO/delivery match) and commits a hash of the underwriting package (`attestation`) on-chain for audit.
- Exposure caps: advance rate ≤ 95% (default 80%), per-borrower credit limit, single-borrower concentration cap, max tenor, max active loans.
- First-loss stake absorbs the first losses, so the delegate pays for bad underwriting.

**Residual:** on-chain checks cannot prove an invoice is real or that it hasn't been factored off-chain. A borrower can vary the debtor or invoice text to get a new key; normalization only catches trivial variations. This is the delegate's job and the reason the first-loss and concentration limits exist.
Hashes of low-entropy identifiers (company numbers, sequential invoice numbers) can be brute-forced, revealing which debtor an invoice is against. No names or amounts beyond face value go on-chain, and documents must be encrypted before pinning.

### 2. Delegate collusion
**Attack:** the delegate funds fake invoices for a colluding borrower and splits the advances.
**Controls:**
- Delegate approval and pool creation are Timelock actions (48h public notice); delegates need KYC.
- The first-loss stake (≥ max(minimum, 5% of outstanding)) is slashed before junior; it can't be withdrawn below the requirement or while any loan is past due.
- Hard caps the delegate can't override: advance rate, fee cap, tenor, per-borrower limit, concentration cap, pool cap.
- The guardian can revoke a delegate instantly across all pools (`Underwriting.revokeDelegate`); all delegate functions check active status on every call.
- Governance can replace the delegate (`setDelegate`); the first-loss stake stays with the pool as cover.
- Every action is evented with the attestation hash, so collusion leaves an audit trail.

**Residual:** a delegate willing to lose its stake can still extract up to (concentration cap × NAV − stake) before detection. Size pool caps to delegate stake and track record; start with the conservative defaults in `Governance.defaultParams` ($2M cap, 25% concentration, $50k minimum stake).

### 3. Senior run before a known default
**Attack:** lenders who learn a loan will default exit before the write-down, pushing the loss onto those who stay; or new money enters at a stale NAV.
**Controls:**
- No instant exits: ERC-4626 `withdraw`/`redeem` revert; exits only through epoch queues (default 30 days).
- Escrowed shares keep bearing losses until processed.
- **Impairment freeze:** while any active loan is past its due date (checked on-chain, no keeper needed), epochs can't close, deposits are blocked and first-loss can't be withdrawn.
- Delegate or governance can declare default early, so fraud is recognized without waiting out grace + default windows.
- Junior and first-loss absorb losses first, which shrinks the incentive for senior to run; senior also redeems first, but only from idle cash.
- $DRFT unstaking has a cooldown (14 days) during which stakes remain slashable.

**Residual:** information that isn't yet on-chain (a borrower's private insolvency) can still leak before the due date. The epoch length and the delegate's early-default power are the levers.

## Other risks

| Risk | Control | Residual |
|---|---|---|
| Reentrancy | `nonReentrant` on every state-changing entry point; checks-effects-interactions throughout (epoch close plans, records, then executes); SafeERC20 | USDG is a trusted, non-callback ERC-20 |
| Share-price inflation / donation | internal cash accounting (donations ignored); 6-decimal ERC-4626 offset; deposits blocked into a wiped tranche that still has shares | — |
| Rounding drift | invariant `senior + junior == cash + outstanding`; per-user claims round down; dust stays in escrow | negligible dust |
| Unbounded loops / gas DoS | max 250 active loans per pool; KYC batches ≤ 200; epoch processing O(1); pagination on all lists | — |
| Oracle failure or manipulation | staleness, round and sign checks; optional sequencer feed; oracle used only for backstop sizing; `tryGetPrice` → skip, never block defaults | no sequencer feed on Robinhood Chain yet |
| USDG issuer actions (pause, freeze, depeg) | none possible on-chain; disclosed | a frozen pool address would halt the pool |
| Key compromise: deployer | holds no role after deploy (asserted by the script) | — |
| Key compromise: proposer | 48h delay + guardian cancel | the Safe threshold is the real control |
| Key compromise: guardian | can only pause/revoke/cancel (liveness attack) | up to 48h downtime to unpause via the Timelock |
| Key compromise: keeper | no protocol power | gas only |
| Clone initialization front-run | factory clones and initializes atomically; implementations call `_disableInitializers` | — |
| Malicious project token | `setProjectToken` once, Timelock-gated, must be a contract and not the reward token; backstop calls wrapped in `try/catch` | token-specific behavior (fees on transfer) would mis-size stakes; vet before activation |
| Frontend / DNS compromise | contracts enforce everything; wallets show calldata | users can still be phished |
| Regulatory | KYC registry, blocklist, optional geoblock, risk disclosure | legal review required before launch |

## Verification performed
- Foundry unit, fuzz (512 runs) and invariant (128 runs × 64 depth) tests, including loss order, waterfall priority and finance-once invariants.
- Fork tests against Robinhood Chain mainnet with real USDG and the real Chainlink feed.
- Slither: 0 high or medium findings.
- Full deploy on a local mainnet fork and a mainnet dry run.

Not yet done: an external audit, formal verification, or a public bug bounty. Do these before taking meaningful TVL.
