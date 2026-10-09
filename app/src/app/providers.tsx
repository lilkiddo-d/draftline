"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { RainbowKitProvider, darkTheme, lightTheme } from "@rainbow-me/rainbowkit";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";
import { WagmiProvider } from "wagmi";
import { wagmiConfig } from "@/lib/wagmi";
import { RiskGate } from "@/components/RiskGate";

export function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(
    () => new QueryClient({ defaultOptions: { queries: { refetchInterval: 12_000, staleTime: 4_000 } } })
  );
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          theme={{ lightMode: lightTheme({ accentColor: "#1f5eff" }), darkMode: darkTheme({ accentColor: "#5b8cff" }) }}
          appInfo={{ appName: "Draftline", learnMoreUrl: "/risk" }}
        >
          <RiskGate>{children}</RiskGate>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
