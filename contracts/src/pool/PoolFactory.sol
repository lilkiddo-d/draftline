// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Guarded} from "../access/Guarded.sol";
import {IUnderwriting, ICreditPool, ITranche} from "../interfaces/IDraftline.sol";
import {PoolParams} from "../libraries/Types.sol";
import {CreditPool} from "./CreditPool.sol";
import {Tranche} from "./Tranche.sol";
import {FirstLossVault} from "./FirstLossVault.sol";
import {EpochRedemptions} from "./EpochRedemptions.sol";

/// @title PoolFactory
/// @notice Deploys a pool as five immutable EIP-1167 clones (pool, senior, junior, first-loss vault, epoch
///         queue), initialises them atomically, and acts as the pool registry, global pause switch and role
///         registry for every pool (pools check DEFAULT_ADMIN_ROLE / GUARDIAN_ROLE here).
///         Pools can only be created by the admin (Timelock) for an Underwriting-approved delegate.
contract PoolFactory is Guarded {
    struct Implementations {
        address creditPool;
        address tranche;
        address firstLossVault;
        address epochRedemptions;
    }

    struct Dependencies {
        address invoiceNFT;
        address compliance;
        address underwriting;
        address defaultManager;
        address feeCollector;
    }

    struct CreatePoolArgs {
        address asset;
        address delegate;
        string name;
        string symbol;
        uint64 epochDuration;
        PoolParams params;
    }

    struct PoolAddresses {
        address pool;
        address seniorTranche;
        address juniorTranche;
        address firstLossVault;
        address epochRedemptions;
    }

    Implementations public implementations;
    Dependencies public dependencies;
    mapping(address => bool) public isPool;
    mapping(address => bool) public allowedAsset;
    address[] internal _pools;

    event PoolCreated(
        address indexed pool,
        address indexed delegate,
        address indexed asset,
        address seniorTranche,
        address juniorTranche,
        address firstLossVault,
        address epochRedemptions,
        string name
    );
    event AssetAllowed(address indexed asset, bool allowed);
    event DependenciesSet(Dependencies deps);

    error AssetNotAllowed(address asset);
    error DelegateNotApproved(address delegate);

    constructor(address admin, address guardian, Implementations memory impls, Dependencies memory deps)
        Guarded(admin, guardian)
    {
        if (
            impls.creditPool == address(0) || impls.tranche == address(0) || impls.firstLossVault == address(0)
                || impls.epochRedemptions == address(0)
        ) revert ZeroAddress();
        implementations = impls;
        _setDependencies(deps);
    }

    function setDependencies(Dependencies calldata deps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDependencies(deps);
    }

    function setAllowedAsset(address asset, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        allowedAsset[asset] = allowed;
        emit AssetAllowed(asset, allowed);
    }

    function createPool(CreatePoolArgs calldata a)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
        returns (PoolAddresses memory out)
    {
        if (!allowedAsset[a.asset]) revert AssetNotAllowed(a.asset);
        Dependencies memory d = dependencies;
        if (!IUnderwriting(d.underwriting).isActiveDelegate(a.delegate)) revert DelegateNotApproved(a.delegate);
        Implementations memory impl = implementations;

        out.pool = Clones.clone(impl.creditPool);
        out.seniorTranche = Clones.clone(impl.tranche);
        out.juniorTranche = Clones.clone(impl.tranche);
        out.firstLossVault = Clones.clone(impl.firstLossVault);
        out.epochRedemptions = Clones.clone(impl.epochRedemptions);

        isPool[out.pool] = true;
        _pools.push(out.pool);
        emit PoolCreated(
            out.pool,
            a.delegate,
            a.asset,
            out.seniorTranche,
            out.juniorTranche,
            out.firstLossVault,
            out.epochRedemptions,
            a.name
        );

        Tranche(out.seniorTranche).initialize(
            IERC20(a.asset),
            ICreditPool(out.pool),
            out.epochRedemptions,
            true,
            string.concat("Draftline ", a.name, " Senior"),
            string.concat("dlS-", a.symbol)
        );
        Tranche(out.juniorTranche).initialize(
            IERC20(a.asset),
            ICreditPool(out.pool),
            out.epochRedemptions,
            false,
            string.concat("Draftline ", a.name, " Junior"),
            string.concat("dlJ-", a.symbol)
        );
        FirstLossVault(out.firstLossVault).initialize(ICreditPool(out.pool), IERC20(a.asset));
        EpochRedemptions(out.epochRedemptions).initialize(
            ICreditPool(out.pool),
            ITranche(out.seniorTranche),
            ITranche(out.juniorTranche),
            IERC20(a.asset),
            a.epochDuration
        );
        CreditPool(out.pool).initialize(
            CreditPool.InitParams({
                delegate: a.delegate,
                asset: a.asset,
                seniorTranche: out.seniorTranche,
                juniorTranche: out.juniorTranche,
                firstLossVault: out.firstLossVault,
                epochRedemptions: out.epochRedemptions,
                invoiceNFT: d.invoiceNFT,
                compliance: d.compliance,
                underwriting: d.underwriting,
                factory: address(this),
                defaultManager: d.defaultManager,
                feeCollector: d.feeCollector,
                name: a.name,
                params: a.params
            })
        );
    }

    function poolCount() external view returns (uint256) {
        return _pools.length;
    }

    function getPools(uint256 offset, uint256 limit) external view returns (address[] memory out) {
        uint256 len = _pools.length;
        if (offset >= len) return new address[](0);
        uint256 end = Math.min(len, offset + limit);
        out = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            out[i - offset] = _pools[i];
        }
    }

    function _setDependencies(Dependencies memory deps) private {
        if (
            deps.invoiceNFT == address(0) || deps.compliance == address(0) || deps.underwriting == address(0)
                || deps.defaultManager == address(0) || deps.feeCollector == address(0)
        ) revert ZeroAddress();
        dependencies = deps;
        emit DependenciesSet(deps);
    }
}
