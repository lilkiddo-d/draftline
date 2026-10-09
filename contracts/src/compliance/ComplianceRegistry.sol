// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ComplianceRegistry
/// @notice KYC allowlist + sanctions blocklist. KYC is required by default for borrowers and delegates and
///         optional (off by default) for lenders. Blocked addresses can never borrow, delegate or lend.
contract ComplianceRegistry is AccessControl {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    uint256 public constant MAX_BATCH = 200;

    bool public requireBorrowerKyc = true;
    bool public requireDelegateKyc = true;
    bool public requireLenderKyc = false;

    mapping(address => uint64) public kycExpiry;
    mapping(address => bool) public isBlocked;

    event KycSet(address indexed account, uint64 expiry);
    event BlockedSet(address indexed account, bool blocked);
    event RequirementsSet(bool borrower, bool delegate, bool lender);

    error ZeroAddress();
    error BatchTooLarge();

    constructor(address admin, address complianceOfficer) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (complianceOfficer != address(0)) _grantRole(COMPLIANCE_ROLE, complianceOfficer);
    }

    function setKyc(address account, uint64 expiry) external onlyRole(COMPLIANCE_ROLE) {
        _setKyc(account, expiry);
    }

    function setKycBatch(address[] calldata accounts, uint64 expiry) external onlyRole(COMPLIANCE_ROLE) {
        uint256 n = accounts.length;
        if (n > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < n; ++i) {
            _setKyc(accounts[i], expiry);
        }
    }

    function setBlocked(address account, bool blocked) external onlyRole(COMPLIANCE_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        isBlocked[account] = blocked;
        emit BlockedSet(account, blocked);
    }

    function setRequirements(bool borrower, bool delegate_, bool lender) external onlyRole(DEFAULT_ADMIN_ROLE) {
        requireBorrowerKyc = borrower;
        requireDelegateKyc = delegate_;
        requireLenderKyc = lender;
        emit RequirementsSet(borrower, delegate_, lender);
    }

    function isKycValid(address account) public view returns (bool) {
        return kycExpiry[account] > block.timestamp;
    }

    function canBorrow(address account) external view returns (bool) {
        return _passes(account, requireBorrowerKyc);
    }

    function canDelegate(address account) external view returns (bool) {
        return _passes(account, requireDelegateKyc);
    }

    function canLend(address account) external view returns (bool) {
        return _passes(account, requireLenderKyc);
    }

    function _passes(address account, bool kycRequired) private view returns (bool) {
        if (account == address(0) || isBlocked[account]) return false;
        return !kycRequired || isKycValid(account);
    }

    function _setKyc(address account, uint64 expiry) private {
        if (account == address(0)) revert ZeroAddress();
        kycExpiry[account] = expiry;
        emit KycSet(account, expiry);
    }
}
