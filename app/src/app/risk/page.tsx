import type { Metadata } from "next";

export const metadata: Metadata = { title: "Risk disclosure — Draftline" };

export default function RiskPage() {
  return (
    <article className="prose" style={{ maxWidth: 780 }}>
      <h1>Risk disclosure</h1>
      <p className="muted">Read this before lending, borrowing, delegating or staking. Last updated with protocol v1.</p>

      <h2>What you are doing</h2>
      <p>
        Depositing into a Draftline tranche lends stablecoins to private businesses that pledge invoices (receivables)
        as collateral. Returns come from the fees those businesses pay. They are not guaranteed.
      </p>

      <h2>Credit and fraud risk</h2>
      <ul>
        <li>Invoice debtors may pay late or never. Borrowers may go insolvent.</li>
        <li>Invoices may be fake, inflated, disputed, or pledged elsewhere off-chain. On-chain checks (unique invoice keys, NFT escrow, a one-time “financed” flag) prevent double-financing <em>within Draftline</em> only. Verifying that an invoice is real is the Pool Delegate&apos;s job, and they can make mistakes or act in bad faith.</li>
        <li>Loss order: the delegate&apos;s first-loss stake, then the Junior tranche, then the Senior tranche. Senior losses may be partly reimbursed by the $DRFT backstop, if it is live and sufficiently funded. It may not be.</li>
        <li>Junior capital can be wiped out by a single large default. Senior capital can also be lost.</li>
      </ul>

      <h2>Liquidity risk</h2>
      <ul>
        <li>Loans are not instantly liquid. Withdrawals are requested per epoch and paid only from idle cash. Senior requests are filled before Junior, and Junior cannot withdraw below the subordination floor.</li>
        <li>While any loan is past due, epoch processing, new deposits and first-loss withdrawals are paused. Queued withdrawals keep bearing losses until processed.</li>
        <li>Partial fills are pro-rata. Unfilled shares are returned, and you must request again.</li>
      </ul>

      <h2>Pricing</h2>
      <p>
        Tranche value is book value: principal at cost plus income actually received. Interest owed but unpaid is not
        counted. A loan is written off only when it defaults, so the share price can drop suddenly at default.
      </p>

      <h2>Smart-contract and operational risk</h2>
      <ul>
        <li>Contracts may contain bugs despite testing and static analysis. They have not been formally verified.</li>
        <li>Governance (a 48-hour Timelock) can change risk parameters, replace a delegate, and activate token features. A guardian can pause pools and revoke delegates immediately.</li>
        <li>The pool asset is USDG (Global Dollar), issued by Paxos. It can be paused or frozen by its issuer and could lose its peg.</li>
        <li>Oracle prices (Chainlink) are used for backstop sizing. No L2 sequencer-uptime feed exists for Robinhood Chain yet.</li>
      </ul>

      <h2>Compliance</h2>
      <ul>
        <li>Borrowers and delegates must complete KYC. Lenders may be required to as well, depending on governance settings.</li>
        <li>Sanctioned or blocked addresses cannot use the protocol. Access may be restricted in some jurisdictions.</li>
        <li>Nothing on this site is an offer of securities, investment advice, or a recommendation. You are responsible for your own tax and legal obligations.</li>
      </ul>

      <h2>$DRFT</h2>
      <p>
        $DRFT is launched separately by third-party infrastructure. Staking it exposes you to slashing when Senior
        losses occur, and to the token&apos;s own price risk. Until governance activates it on-chain, all token
        features are disabled.
      </p>
    </article>
  );
}
