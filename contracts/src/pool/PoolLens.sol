// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {CreditPool} from "./CreditPool.sol";
import {EpochRedemptions} from "./EpochRedemptions.sol";
import {FirstLossVault} from "./FirstLossVault.sol";
import {PoolFactory} from "./PoolFactory.sol";
import {PoolParams, LoanStatus} from "../libraries/Types.sol";

/// @title PoolLens
/// @notice Stateless read helper for frontends and keepers. Holds no funds and no privileges.
contract PoolLens {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;

    struct PoolSummary {
        address pool;
        string name;
        address asset;
        address delegate;
        address seniorTranche;
        address juniorTranche;
        address firstLossVault;
        address epochRedemptions;
        uint256 seniorAssets;
        uint256 juniorAssets;
        uint256 cash;
        uint256 outstandingPrincipal;
        uint256 utilizationBps;
        uint256 seniorSharePrice; // assets per 1e18 shares-unit, scaled 1e18
        uint256 juniorSharePrice;
        uint256 seniorInterestOwed;
        uint256 juniorInterestOwed;
        uint256 firstLossStake;
        uint256 requiredFirstLoss;
        uint256 activeLoans;
        bool impaired;
        bool active;
        uint64 createdAt;
        uint256 currentEpoch;
        uint256 epochEndsAt;
        PoolParams params;
        CreditPool.LossStats losses;
    }

    function summary(CreditPool pool) public view returns (PoolSummary memory s) {
        s.pool = address(pool);
        s.name = pool.name();
        s.asset = address(pool.asset());
        s.delegate = pool.delegate();
        s.seniorTranche = address(pool.seniorTranche());
        s.juniorTranche = address(pool.juniorTranche());
        s.firstLossVault = address(pool.firstLossVault());
        s.epochRedemptions = pool.epochRedemptions();
        s.seniorAssets = pool.seniorAssets();
        s.juniorAssets = pool.juniorAssets();
        s.cash = pool.cash();
        s.outstandingPrincipal = pool.outstandingPrincipal();
        uint256 total = s.seniorAssets + s.juniorAssets;
        s.utilizationBps = total == 0 ? 0 : (s.outstandingPrincipal * BPS) / total;
        s.seniorSharePrice = _sharePrice(IERC4626(s.seniorTranche));
        s.juniorSharePrice = _sharePrice(IERC4626(s.juniorTranche));
        (s.seniorInterestOwed, s.juniorInterestOwed) = pendingInterest(pool);
        s.firstLossStake = FirstLossVault(s.firstLossVault).stake();
        s.requiredFirstLoss = pool.requiredFirstLoss();
        s.activeLoans = pool.activeLoanCount();
        s.impaired = pool.isImpaired();
        s.active = pool.isActive();
        s.createdAt = pool.createdAt();
        EpochRedemptions er = EpochRedemptions(s.epochRedemptions);
        s.currentEpoch = er.currentEpoch();
        s.epochEndsAt = er.epochEndsAt();
        s.params = pool.params();
        s.losses = _losses(pool);
    }

    function summaries(PoolFactory factory, uint256 offset, uint256 limit)
        external
        view
        returns (PoolSummary[] memory out)
    {
        address[] memory pools = factory.getPools(offset, limit);
        out = new PoolSummary[](pools.length);
        for (uint256 i; i < pools.length; ++i) {
            out[i] = summary(CreditPool(pools[i]));
        }
    }

    /// @notice Senior/junior interest owed including accrual up to now.
    function pendingInterest(CreditPool pool) public view returns (uint256 seniorOwed, uint256 juniorOwed) {
        seniorOwed = pool.seniorInterestOwed();
        juniorOwed = pool.juniorInterestOwed();
        uint256 last = pool.lastAccrual();
        uint256 sa = pool.seniorAssets();
        uint256 total = sa + pool.juniorAssets();
        uint256 out = pool.outstandingPrincipal();
        if (block.timestamp <= last || total < 1 || out < 1) return (seniorOwed, juniorOwed);
        uint256 dt = block.timestamp - last;
        PoolParams memory p = pool.params();
        uint256 seniorBase = Math.mulDiv(out, sa, total);
        seniorOwed += Math.mulDiv(seniorBase, uint256(p.seniorRateBps) * dt, BPS * YEAR);
        juniorOwed += Math.mulDiv(out - seniorBase, uint256(p.juniorHurdleBps) * dt, BPS * YEAR);
    }

    /// @notice Amount needed to fully repay `tokenId` right now (includes the late fee once grace has ended).
    function amountOwed(CreditPool pool, uint256 tokenId) external view returns (uint256 owed) {
        CreditPool.Loan memory loan = pool.getLoan(tokenId);
        if (loan.status != LoanStatus.Funded && loan.status != LoanStatus.Late) return 0;
        owed = uint256(loan.feeOwed) + loan.principalOwed;
        PoolParams memory p = pool.params();
        if (!loan.lateFeeCharged && block.timestamp > uint256(loan.dueDate) + p.gracePeriod) {
            owed += (uint256(loan.principalOwed) * p.lateFeeBps) / BPS;
        }
    }

    /// @notice Loans the keeper should act on: past due but not yet marked, and those that can be defaulted.
    function keeperWork(CreditPool pool) external view returns (uint256[] memory markable, uint256[] memory defaultable) {
        uint256[] memory ids = pool.activeLoans(0, pool.activeLoanCount());
        uint256[] memory m = new uint256[](ids.length);
        uint256[] memory d = new uint256[](ids.length);
        uint256 nm = 0;
        uint256 nd = 0;
        for (uint256 i; i < ids.length; ++i) {
            CreditPool.Loan memory loan = pool.getLoan(ids[i]);
            if (block.timestamp >= pool.defaultableAt(ids[i])) d[nd++] = ids[i];
            else if (loan.status == LoanStatus.Funded && block.timestamp > loan.dueDate) m[nm++] = ids[i];
        }
        markable = _trim(m, nm);
        defaultable = _trim(d, nd);
    }

    function _sharePrice(IERC4626 tranche) private view returns (uint256) {
        uint256 unit = 10 ** IERC4626(address(tranche)).decimals();
        return Math.mulDiv(tranche.convertToAssets(unit), 1e18, 10 ** IERC20Decimals(address(tranche.asset())).decimals());
    }

    function _losses(CreditPool pool) private view returns (CreditPool.LossStats memory l) {
        (l.defaults, l.totalWrittenOff, l.firstLossAbsorbed, l.juniorAbsorbed, l.seniorAbsorbed, l.recovered) =
            pool.lossStats();
    }

    function _trim(uint256[] memory a, uint256 n) private pure returns (uint256[] memory out) {
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = a[i];
        }
    }
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}
