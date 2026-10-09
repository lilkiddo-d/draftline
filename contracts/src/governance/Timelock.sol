// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title Timelock
/// @notice Owner of every privileged role in Draftline. Enforces a minimum 48h delay; self-administered
///         (no external admin). An optional guardian may cancel queued operations (veto) but never propose.
contract Timelock is TimelockController {
    uint256 public constant MIN_DELAY_FLOOR = 48 hours;

    error DelayTooShort(uint256 delay);

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address canceller)
        TimelockController(minDelay, proposers, executors, address(0))
    {
        if (minDelay < MIN_DELAY_FLOOR) revert DelayTooShort(minDelay);
        if (canceller != address(0)) _grantRole(CANCELLER_ROLE, canceller);
    }

    /// @dev Prevent the timelock from ever lowering its own delay below the 48h floor.
    function updateDelay(uint256 newDelay) public override {
        if (newDelay < MIN_DELAY_FLOOR) revert DelayTooShort(newDelay);
        super.updateDelay(newDelay);
    }
}
