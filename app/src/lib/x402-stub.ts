// Stub for the optional `@x402/*` packages referenced by Coinbase's CDP SDK (pulled in transitively by
// wagmi's Base Account connector). Draftline never uses x402 payments; any call fails loudly.
const unsupported = (name: string) => {
  const fn = function () {
    throw new Error(`${name} (x402) is not available in Draftline`);
  } as unknown as { new (...a: unknown[]): unknown; (...a: unknown[]): unknown };
  return fn;
};
export const AuthCaptureEvmScheme = unsupported("AuthCaptureEvmScheme");
export const BatchSettlementEvmScheme = unsupported("BatchSettlementEvmScheme");
export const ExactEvmScheme = unsupported("ExactEvmScheme");
export const ExactEvmSchemeV1 = unsupported("ExactEvmSchemeV1");
export const ExactSvmScheme = unsupported("ExactSvmScheme");
export const ExactSvmSchemeV1 = unsupported("ExactSvmSchemeV1");
export const UptoEvmScheme = unsupported("UptoEvmScheme");
export const UptoSvmScheme = unsupported("UptoSvmScheme");
export const HTTPFacilitatorClient = unsupported("HTTPFacilitatorClient");
export const x402Client = unsupported("x402Client");
export const x402ResourceServer = unsupported("x402ResourceServer");
export const x402HTTPResourceServer = unsupported("x402HTTPResourceServer");
export const registerExactEvmScheme = unsupported("registerExactEvmScheme");
export const toClientEvmSigner = unsupported("toClientEvmSigner");
export const wrapFetchWithPayment = unsupported("wrapFetchWithPayment");
export const paymentMiddlewareFromConfig = unsupported("paymentMiddlewareFromConfig");
export const paymentMiddlewareFromHTTPServer = unsupported("paymentMiddlewareFromHTTPServer");
export const bazaarResourceServerExtension = {};
export const builderCodeResourceServerExtension = {};
export const BuilderCodeClientExtension = unsupported("BuilderCodeClientExtension");
export const BUILDER_CODE = "";
export const BUILDER_CODE_PATTERN = /.*/;
export const BUILDER_CODE_SCHEMA = {};
export const PaymentRequirementsV1Schema = {};
export const PaymentRequirementsV2Schema = {};
export default {};
