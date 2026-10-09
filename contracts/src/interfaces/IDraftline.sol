// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {InvoiceStatus, LoanStatus, PoolParams} from "../libraries/Types.sol";

interface IComplianceRegistry {
    function canBorrow(address account) external view returns (bool);
    function canDelegate(address account) external view returns (bool);
    function canLend(address account) external view returns (bool);
    function isBlocked(address account) external view returns (bool);
}

interface IUnderwriting {
    function isActiveDelegate(address account) external view returns (bool);
}

interface IPoolRegistry {
    function isPool(address pool) external view returns (bool);
    function paused() external view returns (bool);
}

interface IInvoiceNFT is IERC721 {
    function terms(uint256 tokenId)
        external
        view
        returns (address borrower, uint256 faceValue, uint64 dueDate, InvoiceStatus status, bool financed);
    function markSubmitted(uint256 tokenId) external;
    function markFinanced(uint256 tokenId) external;
    function markReleased(uint256 tokenId) external;
    function markRepaid(uint256 tokenId) external;
    function markDefaulted(uint256 tokenId) external;
}

interface ITranche is IERC4626 {
    function isSenior() external view returns (bool);
    function burnFrom(address account, uint256 shares) external;
}

interface IFirstLossVault {
    function stake() external view returns (uint256);
    function slash(uint256 amount) external returns (uint256 slashed);
    function notifyDeposit(uint256 amount) external;
}

interface ICreditPool {
    function asset() external view returns (address);
    function delegate() external view returns (address);
    function seniorTranche() external view returns (address);
    function juniorTranche() external view returns (address);
    function trancheAssets(bool senior) external view returns (uint256);
    function maxDeposit(bool senior, address receiver) external view returns (uint256);
    function recordDeposit(bool senior, address caller, address receiver, uint256 assets) external;
    function redeemableAssets(bool senior) external view returns (uint256);
    function cash() external view returns (uint256);
    function seniorAssets() external view returns (uint256);
    function juniorAssets() external view returns (uint256);
    function maxSeniorRatioBps() external view returns (uint256);
    function executeRedemption(bool senior, uint256 shares) external returns (uint256 assets);
    function canHoldShares(address account) external view returns (bool);
    function isActive() external view returns (bool);
    function isImpaired() external view returns (bool);
    function requiredFirstLoss() external view returns (uint256);
    function defaultableAt(uint256 tokenId) external view returns (uint256);
    function markPastDue(uint256 tokenId) external;
    function writeOff(uint256 tokenId) external returns (uint256 seniorLoss);
}

interface IProjectTokenHooks {
    function isActive() external view returns (bool);
    function canReceiveRewards() external view returns (bool);
    function notifyRewards(uint256 amount) external;
    function coverSeniorLoss(address pool, uint256 tokenId, uint256 lossAssets) external returns (uint256 slashed);
}

interface IOracleAdapter {
    function getPrice(address token) external view returns (uint256 price1e18);
    function tryGetPrice(address token) external view returns (bool ok, uint256 price1e18);
}

/// @dev Minimal Chainlink aggregator interface.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
