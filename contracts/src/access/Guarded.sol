// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title Guarded
/// @notice Shared admin/guardian pattern for singleton contracts. DEFAULT_ADMIN_ROLE is handed to the
///         48h Timelock at deploy. The guardian (fast, low-privilege) can only pause; unpausing needs admin.
abstract contract Guarded is AccessControl, Pausable {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    error ZeroAddress();

    constructor(address admin, address guardian) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (guardian != address(0)) _grantRole(GUARDIAN_ROLE, guardian);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
