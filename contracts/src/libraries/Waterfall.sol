// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Waterfall
/// @notice Pure cash-flow priority rules shared by every CreditPool. Kept as an internal library so the
///         rules are inlined (no external trust surface) and can be fuzzed in isolation.
/// @dev Income:   senior interest owed -> junior hurdle owed -> protocol fee / delegate fee on excess -> junior.
///      Loss:     first-loss stake -> junior NAV -> senior NAV (protocol backstop then reimburses senior).
///      Recovery: senior write-down -> senior interest owed -> junior write-down -> first-loss write-down
///                -> excess treated as income. Junior is never paid while senior interest is in arrears.
library Waterfall {
    uint256 internal constant BPS = 10_000;

    struct IncomeSplit {
        uint256 senior;
        uint256 juniorHurdle;
        uint256 juniorResidual;
        uint256 protocol;
        uint256 delegate;
    }

    struct LossSplit {
        uint256 firstLoss;
        uint256 junior;
        uint256 senior;
        uint256 uncovered;
    }

    struct RecoverySplit {
        uint256 senior;
        uint256 seniorInterest;
        uint256 junior;
        uint256 firstLoss;
        uint256 excess;
    }

    /// @dev Requires protocolFeeBps + delegateFeeBps <= BPS (enforced by pool parameter validation).
    function distributeIncome(
        uint256 amount,
        uint256 seniorOwed,
        uint256 juniorOwed,
        uint256 protocolFeeBps,
        uint256 delegateFeeBps
    ) internal pure returns (IncomeSplit memory s) {
        s.senior = _min(amount, seniorOwed);
        uint256 rem = amount - s.senior;
        s.juniorHurdle = _min(rem, juniorOwed);
        rem -= s.juniorHurdle;
        s.protocol = (rem * protocolFeeBps) / BPS;
        s.delegate = (rem * delegateFeeBps) / BPS;
        s.juniorResidual = rem - s.protocol - s.delegate;
    }

    function allocateLoss(uint256 loss, uint256 firstLossAvailable, uint256 juniorAssets, uint256 seniorAssets)
        internal
        pure
        returns (LossSplit memory s)
    {
        s.firstLoss = _min(loss, firstLossAvailable);
        uint256 rem = loss - s.firstLoss;
        s.junior = _min(rem, juniorAssets);
        rem -= s.junior;
        s.senior = _min(rem, seniorAssets);
        s.uncovered = rem - s.senior;
    }

    function allocateRecovery(
        uint256 amount,
        uint256 seniorWritedown,
        uint256 seniorInterestOwed,
        uint256 juniorWritedown,
        uint256 firstLossWritedown
    ) internal pure returns (RecoverySplit memory s) {
        s.senior = _min(amount, seniorWritedown);
        uint256 rem = amount - s.senior;
        s.seniorInterest = _min(rem, seniorInterestOwed);
        rem -= s.seniorInterest;
        s.junior = _min(rem, juniorWritedown);
        rem -= s.junior;
        s.firstLoss = _min(rem, firstLossWritedown);
        s.excess = rem - s.firstLoss;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
