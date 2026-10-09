# $DRFT integration

Draftline does **not** write or deploy a token. $DRFT is launched separately on a launchpad. The protocol works
completely without it; every token feature is dormant until governance turns it on.

## What the token does

$DRFT stakers form a **protocol-wide backstop** for Senior lenders, and are paid for that risk with a share of
protocol fees.

```
default loss ──► first-loss stake ──► Junior NAV ──► Senior NAV
                                                      │
                     ProjectTokenHooks.coverSeniorLoss ◄┘  (only the part that reached Senior)
                       slashes up to maxSlashBps of staked $DRFT, valued by OracleAdapter,
                       sends it to the liquidator ──► liquidator sells ──► CreditPool.recover()
                                                                            restores Senior first
protocol fees ──► FeeCollector.distribute ──► stakerShareBps → stakers (in USDG), rest → treasury
```

| Parameter | Default | Bounds | Where |
|---|---|---|---|
| Staker share of protocol fees | 30% | ≤ 80% | `FeeCollector.setStakerShareBps` |
| Max slash per default | 30% of total stake | ≤ 50% | `ProjectTokenHooks.setRiskParams` |
| Unstake cooldown (stake still slashable) | 14 days | ≤ 90 days | `ProjectTokenHooks.setRiskParams` |
| Liquidator (receives slashed $DRFT) | treasury (= Timelock unless `TREASURY` set) | any address | `ProjectTokenHooks.setConfig` |

All of these are Timelock actions.

## Contracts involved

- **`ProjectTokenHooks`** holds every $DRFT feature: `setProjectToken`, staking (share-based, so slashing is O(1) and pro-rata), cooldowns, USDG reward accounting, and `coverSeniorLoss`.
- **`FeeCollector`** sends the staker share only when `hooks.canReceiveRewards()` (token set and someone staked); otherwise everything goes to the treasury.
- **`DefaultManager`** calls `coverSeniorLoss` after a write-down that reached Senior, inside `try/catch`, so a token or oracle problem can never block a default.
- **`OracleAdapter`** values the loss (USDG/USD, live Chainlink feed) and $DRFT (any AggregatorV3-compatible source that governance registers).

## Until the token is set

- `stake` reverts (`TokenNotSet`); `coverSeniorLoss` returns 0; `canReceiveRewards` is false, so 100% of fees go to the treasury.
- The frontend hides the Backstop page when `NEXT_PUBLIC_PROJECT_TOKEN` is empty.
- Nothing else in the protocol reads the token.

## Activating it (after the launchpad deploy)

1. Vet the token: a standard ERC-20 with no transfer fees or rebasing. Fee-on-transfer would mis-size stakes.
2. Provide a USD price source for $DRFT. Chainlink won't list a new token at launch, so deploy or choose an AggregatorV3-compatible TWAP wrapper over a deep pool, and review it. Without a price, the backstop simply covers nothing (stakers still earn fees), which is safe but pointless.
3. Queue and execute via the Timelock (48h each; see DEPLOY.md §3):
   - `Governance.setOracleFeed(DRFT, feed, heartbeat, …)`
   - `Governance.setProjectToken(DRFT, …)`: callable **once, ever**; rejects zero, EOAs and USDG
4. Set `NEXT_PUBLIC_PROJECT_TOKEN=<DRFT address>` in Vercel and redeploy the app.
5. Announce cooldown, slash cap and staker share so stakers understand the risk.

## Risks for stakers

- Up to `maxSlashBps` of the whole stake can be slashed per default that reaches Senior, at the oracle price.
- A cooldown in progress doesn't protect the stake.
- The $DRFT price can fall independently of protocol performance.
- Rewards are paid only from real protocol fees, in USDG.

## Tests

`test/unit/ProjectToken.t.sol` (token-less operation, set-once, staking, rewards, pro-rata slashing in cooldown, admin bounds), `test/unit/Defaults.t.sol` (backstop covers Senior, cap, stale price skips, reverting hooks don't block defaults), and `test/fork/RobinhoodFork.t.sol::test_fork_default_withBackstop` (real USDG/USD feed). All use a mock ERC-20 that exists only in tests.
