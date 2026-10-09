// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolParams} from "./Types.sol";

/// @title PoolParamsLib
/// @notice Hard bounds on pool risk parameters. Deployed as an external library (keeps CreditPool small)
///         and enforced on pool creation and on every Timelock parameter change.
library PoolParamsLib {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_ACTIVE_LOANS = 250;

    function isValid(PoolParams memory p) external pure returns (bool) {
        return p.advanceRateBps != 0 && p.advanceRateBps <= 9_500 && p.maxSeniorRatioBps <= 9_000
            && p.seniorRateBps <= 5_000 && p.juniorHurdleBps <= 10_000
            && uint256(p.protocolFeeBps) + p.delegateFeeBps <= 5_000 && p.minFirstLossBps <= 5_000
            && p.lateFeeBps <= 2_000 && p.maxFeeBps <= 5_000 && p.maxBorrowerConcentrationBps != 0
            && p.maxBorrowerConcentrationBps <= BPS && p.maxActiveLoans != 0 && p.maxActiveLoans <= MAX_ACTIVE_LOANS
            && p.gracePeriod <= 60 days && p.defaultWindow >= 1 days && p.defaultWindow <= 365 days
            && p.maxTenor >= 1 days && p.maxTenor <= 730 days && p.poolCap != 0;
    }
}
