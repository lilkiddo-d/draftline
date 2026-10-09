import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  transpilePackages: ["@draftline/config"],
  // WalletConnect pulls optional Node-only deps; they are never used in the browser bundle.
  turbopack: {
    resolveAlias: {
      "pino-pretty": { browser: "./src/lib/empty.ts" },
      lokijs: { browser: "./src/lib/empty.ts" },
      encoding: { browser: "./src/lib/empty.ts" },
      // Optional x402 payment deps of the Base Account connector (unused by Draftline).
      "@x402/core/client": "./src/lib/x402-stub.ts",
      "@x402/core/server": "./src/lib/x402-stub.ts",
      "@x402/core/schemas": "./src/lib/x402-stub.ts",
      "@x402/evm": "./src/lib/x402-stub.ts",
      "@x402/evm/exact/client": "./src/lib/x402-stub.ts",
      "@x402/evm/exact/server": "./src/lib/x402-stub.ts",
      "@x402/evm/exact/v1/client": "./src/lib/x402-stub.ts",
      "@x402/evm/upto/client": "./src/lib/x402-stub.ts",
      "@x402/evm/upto/server": "./src/lib/x402-stub.ts",
      "@x402/evm/auth-capture/client": "./src/lib/x402-stub.ts",
      "@x402/evm/batch-settlement/client": "./src/lib/x402-stub.ts",
      "@x402/svm/exact/client": "./src/lib/x402-stub.ts",
      "@x402/svm/exact/server": "./src/lib/x402-stub.ts",
      "@x402/svm/exact/v1/client": "./src/lib/x402-stub.ts",
      "@x402/svm/upto/client": "./src/lib/x402-stub.ts",
      "@x402/svm/upto/server": "./src/lib/x402-stub.ts",
      "@x402/extensions/bazaar": "./src/lib/x402-stub.ts",
      "@x402/extensions/builder-code": "./src/lib/x402-stub.ts",
      "@x402/express": "./src/lib/x402-stub.ts",
      "@x402/fetch": "./src/lib/x402-stub.ts",
    },
  },
  async headers() {
    return [
      {
        source: "/(.*)",
        headers: [
          { key: "X-Frame-Options", value: "DENY" },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
        ],
      },
    ];
  },
};

export default nextConfig;
