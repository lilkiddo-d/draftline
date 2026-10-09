// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IComplianceRegistry} from "../interfaces/IDraftline.sol";

/// @title Underwriting
/// @notice Registry of approved Pool Delegates (underwriters). Approval is a Timelock (admin) action;
///         the guardian can revoke instantly to stop a colluding or compromised delegate across all pools.
contract Underwriting is AccessControl {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    struct DelegateInfo {
        bool approved;
        uint64 approvedAt;
        string metadataURI;
    }

    IComplianceRegistry public immutable compliance;
    mapping(address => DelegateInfo) private _delegates;

    event DelegateApproved(address indexed delegate, string metadataURI);
    event DelegateRevoked(address indexed delegate, address indexed by);

    error ZeroAddress();
    error NotCompliant(address account);
    error Unauthorized();

    constructor(address admin, address guardian, IComplianceRegistry compliance_) {
        if (admin == address(0) || address(compliance_) == address(0)) revert ZeroAddress();
        compliance = compliance_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (guardian != address(0)) _grantRole(GUARDIAN_ROLE, guardian);
    }

    function approveDelegate(address delegate, string calldata metadataURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (delegate == address(0)) revert ZeroAddress();
        if (!compliance.canDelegate(delegate)) revert NotCompliant(delegate);
        _delegates[delegate] = DelegateInfo(true, uint64(block.timestamp), metadataURI);
        emit DelegateApproved(delegate, metadataURI);
    }

    function revokeDelegate(address delegate) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)) revert Unauthorized();
        _delegates[delegate].approved = false;
        emit DelegateRevoked(delegate, msg.sender);
    }

    function isActiveDelegate(address account) external view returns (bool) {
        return _delegates[account].approved && compliance.canDelegate(account);
    }

    function delegateInfo(address account) external view returns (DelegateInfo memory) {
        return _delegates[account];
    }
}
