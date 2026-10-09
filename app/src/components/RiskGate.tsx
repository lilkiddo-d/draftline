"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState, type ReactNode } from "react";

const KEY = "draftline.risk-ack.v1";

/** Requires a one-time acknowledgement of the key risks before using the app (the /risk page stays open). */
export function RiskGate({ children }: { children: ReactNode }) {
  const path = usePathname();
  const [ack, setAck] = useState<boolean | null>(null);
  const [checked, setChecked] = useState(false);

  useEffect(() => {
    try {
      setAck(localStorage.getItem(KEY) === "1");
    } catch {
      setAck(false);
    }
  }, []);

  const accept = () => {
    try {
      localStorage.setItem(KEY, "1");
    } catch {}
    setAck(true);
  };

  return (
    <>
      {children}
      {ack === false && path !== "/risk" && (
        <div className="overlay" role="dialog" aria-modal="true" aria-labelledby="risk-title">
          <div className="card modal">
            <h2 id="risk-title">Before you continue</h2>
            <ul className="small">
              <li>Draftline pools lend to private businesses against invoices. Borrowers and their customers can fail to pay.</li>
              <li>Losses are absorbed by the delegate&apos;s first-loss stake, then the Junior tranche, then the Senior tranche. You can lose all capital.</li>
              <li>Withdrawals are processed in epochs and only from idle cash. They can be delayed or partially filled, especially while a loan is past due.</li>
              <li>Smart contracts may contain bugs. Pool delegates and governance are trusted parties.</li>
              <li>This is not investment advice. Use is subject to local law; some jurisdictions are restricted.</li>
            </ul>
            <label className="row" style={{ color: "var(--text)", margin: "12px 0" }}>
              <input type="checkbox" checked={checked} onChange={(e) => setChecked(e.target.checked)} />
              I have read and understand the <Link href="/risk">risk disclosure</Link>.
            </label>
            <button className="btn" disabled={!checked} onClick={accept}>
              Continue
            </button>
          </div>
        </div>
      )}
    </>
  );
}
