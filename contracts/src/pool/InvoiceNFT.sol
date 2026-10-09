// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Guarded} from "../access/Guarded.sol";
import {IComplianceRegistry, IPoolRegistry} from "../interfaces/IDraftline.sol";
import {InvoiceStatus} from "../libraries/Types.sol";

/// @title InvoiceNFT
/// @notice One ERC-721 per receivable. Anti-double-pledge design:
///         1. `invoiceKey = keccak256(debtorRefHash, invoiceNumberHash)` can be registered exactly once, ever.
///         2. Tokens can only move borrower <-> registered pool (no transfers to third parties or other markets).
///         3. `financed` is a one-way latch set by the holding pool; a financed invoice can never be financed again.
contract InvoiceNFT is ERC721, Guarded {
    using Strings for uint256;

    uint256 public constant MAX_CID_LENGTH = 128;

    struct Invoice {
        address borrower;
        uint64 dueDate;
        uint64 createdAt;
        InvoiceStatus status;
        bool financed;
        uint128 faceValue;
        bytes32 debtorRefHash;
        bytes32 invoiceNumberHash;
        string docCID;
    }

    IComplianceRegistry public immutable compliance;
    IPoolRegistry public poolRegistry;
    uint256 public nextTokenId = 1;

    mapping(uint256 => Invoice) private _invoices;
    mapping(bytes32 => uint256) public tokenOfKey;

    event InvoiceMinted(
        uint256 indexed tokenId,
        address indexed borrower,
        uint256 faceValue,
        uint64 dueDate,
        bytes32 debtorRefHash,
        bytes32 invoiceNumberHash,
        string docCID
    );
    event InvoiceStatusChanged(uint256 indexed tokenId, InvoiceStatus status);
    event PoolRegistrySet(address registry);

    error NotCompliant(address account);
    error DuplicateInvoice(bytes32 key, uint256 existingTokenId);
    error InvalidInvoice();
    error AlreadySet();
    error NotHoldingPool();
    error AlreadyFinanced(uint256 tokenId);
    error BadStatus(InvoiceStatus status);
    error TransferRestricted();

    constructor(address admin, address guardian, IComplianceRegistry compliance_)
        ERC721("Draftline Invoice", "DLINV")
        Guarded(admin, guardian)
    {
        if (address(compliance_) == address(0)) revert ZeroAddress();
        compliance = compliance_;
    }

    /// @notice One-time wiring to the PoolFactory (pool registry).
    function setPoolRegistry(IPoolRegistry registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(poolRegistry) != address(0)) revert AlreadySet();
        if (address(registry) == address(0)) revert ZeroAddress();
        poolRegistry = registry;
        emit PoolRegistrySet(address(registry));
    }

    function invoiceKey(bytes32 debtorRefHash, bytes32 invoiceNumberHash) public pure returns (bytes32) {
        return keccak256(abi.encode(debtorRefHash, invoiceNumberHash));
    }

    function mint(
        uint128 faceValue,
        uint64 dueDate,
        bytes32 debtorRefHash,
        bytes32 invoiceNumberHash,
        string calldata docCID
    ) external whenNotPaused returns (uint256 tokenId) {
        if (!compliance.canBorrow(msg.sender)) revert NotCompliant(msg.sender);
        uint256 cidLen = bytes(docCID).length;
        if (
            faceValue == 0 || dueDate <= block.timestamp || debtorRefHash == bytes32(0)
                || invoiceNumberHash == bytes32(0) || cidLen == 0 || cidLen > MAX_CID_LENGTH
        ) revert InvalidInvoice();
        bytes32 key = invoiceKey(debtorRefHash, invoiceNumberHash);
        if (tokenOfKey[key] != 0) revert DuplicateInvoice(key, tokenOfKey[key]);

        tokenId = nextTokenId++;
        tokenOfKey[key] = tokenId;
        _invoices[tokenId] = Invoice({
            borrower: msg.sender,
            dueDate: dueDate,
            createdAt: uint64(block.timestamp),
            status: InvoiceStatus.Minted,
            financed: false,
            faceValue: faceValue,
            debtorRefHash: debtorRefHash,
            invoiceNumberHash: invoiceNumberHash,
            docCID: docCID
        });
        emit InvoiceMinted(tokenId, msg.sender, faceValue, dueDate, debtorRefHash, invoiceNumberHash, docCID);
        _mint(msg.sender, tokenId);
    }

    /// @notice Borrower cancels an unpledged invoice. The invoice key stays consumed forever.
    function cancel(uint256 tokenId) external {
        Invoice storage inv = _invoices[tokenId];
        if (inv.status != InvoiceStatus.Minted || inv.financed) revert BadStatus(inv.status);
        if (ownerOf(tokenId) != msg.sender || inv.borrower != msg.sender) revert NotHoldingPool();
        inv.status = InvoiceStatus.Cancelled;
        emit InvoiceStatusChanged(tokenId, InvoiceStatus.Cancelled);
        _burn(tokenId);
    }

    // ----------------------------------------------------------------- pool hooks

    modifier onlyHoldingPool(uint256 tokenId) {
        if (!_isPool(msg.sender) || _ownerOf(tokenId) != msg.sender) revert NotHoldingPool();
        _;
    }

    function markSubmitted(uint256 tokenId) external onlyHoldingPool(tokenId) {
        _transition(tokenId, InvoiceStatus.Minted, InvoiceStatus.Submitted);
    }

    function markFinanced(uint256 tokenId) external onlyHoldingPool(tokenId) {
        Invoice storage inv = _invoices[tokenId];
        if (inv.financed) revert AlreadyFinanced(tokenId);
        inv.financed = true;
        _transition(tokenId, InvoiceStatus.Submitted, InvoiceStatus.Financed);
    }

    /// @notice Pool returns an unfinanced submission to the borrower (rejected or withdrawn).
    function markReleased(uint256 tokenId) external onlyHoldingPool(tokenId) {
        _transition(tokenId, InvoiceStatus.Submitted, InvoiceStatus.Minted);
    }

    function markRepaid(uint256 tokenId) external onlyHoldingPool(tokenId) {
        _transition(tokenId, InvoiceStatus.Financed, InvoiceStatus.Repaid);
    }

    function markDefaulted(uint256 tokenId) external onlyHoldingPool(tokenId) {
        _transition(tokenId, InvoiceStatus.Financed, InvoiceStatus.Defaulted);
    }

    // ----------------------------------------------------------------- views

    function terms(uint256 tokenId)
        external
        view
        returns (address borrower, uint256 faceValue, uint64 dueDate, InvoiceStatus status, bool financed)
    {
        Invoice storage inv = _invoices[tokenId];
        return (inv.borrower, inv.faceValue, inv.dueDate, inv.status, inv.financed);
    }

    function getInvoice(uint256 tokenId) external view returns (Invoice memory) {
        return _invoices[tokenId];
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Invoice storage inv = _invoices[tokenId];
        bytes memory json = abi.encodePacked(
            '{"name":"Draftline Invoice #',
            tokenId.toString(),
            '","description":"Tokenized receivable. Documents are encrypted off-chain.","attributes":[',
            '{"trait_type":"faceValue","value":"',
            uint256(inv.faceValue).toString(),
            '"},{"trait_type":"dueDate","display_type":"date","value":',
            uint256(inv.dueDate).toString(),
            '},{"trait_type":"status","value":',
            uint256(uint8(inv.status)).toString(),
            '},{"trait_type":"financed","value":',
            inv.financed ? "true" : "false",
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ----------------------------------------------------------------- internals

    /// @dev Restrict movement to mint, burn, or borrower <-> registered pool.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && !_isPool(from) && !_isPool(to)) {
            revert TransferRestricted();
        }
        return super._update(to, tokenId, auth);
    }

    function _isPool(address account) private view returns (bool) {
        IPoolRegistry registry = poolRegistry;
        return address(registry) != address(0) && registry.isPool(account);
    }

    function _transition(uint256 tokenId, InvoiceStatus expected, InvoiceStatus next) private {
        Invoice storage inv = _invoices[tokenId];
        if (inv.status != expected) revert BadStatus(inv.status);
        inv.status = next;
        emit InvoiceStatusChanged(tokenId, next);
    }
}
