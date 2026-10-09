import type { Metadata } from "next";
import "./globals.css";
import { Providers } from "./providers";
import { Header } from "@/components/Header";

export const metadata: Metadata = {
  title: "Draftline — on-chain private credit",
  description: "Invoice and receivables financing in senior and junior risk tranches, funded by stablecoin lenders.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Header />
          <main className="container">
            {children}
            <footer className="footer">
              Draftline is experimental software. Lending to private businesses can result in total loss of capital.
              Nothing here is investment advice. <a href="/risk">Read the risk disclosure</a>.
            </footer>
          </main>
        </Providers>
      </body>
    </html>
  );
}
