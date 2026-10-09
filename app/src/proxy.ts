import { NextResponse, type NextRequest } from "next/server";

/**
 * Optional geoblock. NEXT_PUBLIC_GEOBLOCK_COUNTRIES = comma-separated ISO-3166 alpha-2 codes (e.g. "US,KP,IR").
 * Country comes from Vercel's `x-vercel-ip-country` header; unknown country = allowed. This is a frontend
 * control only — the contracts' ComplianceRegistry is the enforcement layer.
 */
const blocked = (process.env.NEXT_PUBLIC_GEOBLOCK_COUNTRIES || "")
  .split(",")
  .map((c) => c.trim().toUpperCase())
  .filter(Boolean);

export function proxy(request: NextRequest) {
  if (!blocked.length) return NextResponse.next();
  const country = request.headers.get("x-vercel-ip-country")?.toUpperCase();
  if (country && blocked.includes(country) && request.nextUrl.pathname !== "/restricted") {
    return NextResponse.rewrite(new URL("/restricted", request.url));
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/|favicon|icon|restricted|risk).*)"],
};
