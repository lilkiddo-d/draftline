"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { chainConfig, isLocal, tokenFeaturesEnabled } from "@/lib/chain";

const links = [
  { href: "/", label: "Pools" },
  { href: "/borrow", label: "Borrow" },
  { href: "/delegate", label: "Delegate" },
  ...(tokenFeaturesEnabled ? [{ href: "/stake", label: "Backstop" }] : []),
  { href: "/risk", label: "Risks" },
];

export function Header() {
  const path = usePathname();
  return (
    <header className="header">
      <div className="header-inner">
        <Link href="/" className="brand">
          <span className="brand-mark" aria-hidden />
          Draftline
        </Link>
        <nav className="nav">
          {links.map((l) => (
            <Link key={l.href} href={l.href} className={path === l.href || (l.href !== "/" && path.startsWith(l.href)) ? "active" : ""}>
              {l.label}
            </Link>
          ))}
        </nav>
        <span className={`badge ${isLocal ? "warn" : ""}`}>{chainConfig.name}</span>
        <ConnectButton showBalance={false} chainStatus="none" accountStatus="address" />
      </div>
    </header>
  );
}
