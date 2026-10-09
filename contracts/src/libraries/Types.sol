// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Lifecycle of an invoice NFT.
enum InvoiceStatus {
    None,
    Minted, // held by the borrower, not pledged
    Submitted, // escrowed in a pool, awaiting delegate decision
    Financed, // advance paid out; can never be financed again
    Repaid, // fully repaid, returned to borrower as a record
    Defaulted, // written off; NFT stays in the pool for recovery tracking
    Cancelled // burned by the borrower before submission
}

/// @notice Lifecycle of a loan inside a CreditPool.
enum LoanStatus {
    None,
    Submitted,
    Funded,
    Late,
    Repaid,
    Defaulted
}

/// @notice Risk parameters of a pool. All `*Bps` values are basis points (1e4 = 100%).
struct PoolParams {
    uint16 advanceRateBps; // max advance as share of invoice face value
    uint16 maxSeniorRatioBps; // senior NAV may not exceed this share of pool NAV (junior subordination)
    uint16 seniorRateBps; // senior target APR, paid first from income
    uint16 juniorHurdleBps; // junior hurdle APR, paid second
    uint16 protocolFeeBps; // share of excess spread (after senior + junior hurdle) to protocol
    uint16 delegateFeeBps; // share of excess spread to the delegate's first-loss stake
    uint16 minFirstLossBps; // first-loss stake must be >= this share of outstanding principal
    uint16 lateFeeBps; // one-off late fee on outstanding principal once the grace period ends
    uint16 maxFeeBps; // cap on the financing fee a delegate can set per invoice
    uint16 maxBorrowerConcentrationBps; // single-borrower exposure cap vs pool NAV
    uint16 maxActiveLoans; // bound on concurrently active loans (keeps every loop bounded)
    uint32 gracePeriod; // seconds after due date before the late fee applies
    uint32 defaultWindow; // seconds after the grace period before anyone can trigger default
    uint32 maxTenor; // max seconds from funding to invoice due date
    uint128 poolCap; // max pool NAV (senior + junior)
    uint128 minFirstLossAmount; // absolute minimum first-loss stake before any funding
}
