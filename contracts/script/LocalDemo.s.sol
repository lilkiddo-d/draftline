// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RobinhoodChain} from "./ChainConfig.sol";
import {ComplianceRegistry} from "../src/compliance/ComplianceRegistry.sol";
import {Underwriting} from "../src/compliance/Underwriting.sol";
import {InvoiceNFT} from "../src/pool/InvoiceNFT.sol";
import {PoolFactory} from "../src/pool/PoolFactory.sol";
import {CreditPool} from "../src/pool/CreditPool.sol";
import {Tranche} from "../src/pool/Tranche.sol";
import {FirstLossVault} from "../src/pool/FirstLossVault.sol";
import {PoolParams} from "../src/libraries/Types.sol";

/// @title LocalDemo
/// @notice LOCAL FORK ONLY (chain 31337). Seeds a demo pool so the frontend can be exercised end to end:
///         KYC, delegate approval and pool creation (impersonating the Timelock — impossible on mainnet),
///         USDG balances (via anvil_setStorageAt), first-loss stake, tranche deposits and two invoices.
///         Requires `anvil --auto-impersonate`; run with `--unlocked --sender <deployer>`. No keys involved.
///         Optional env DEMO_WALLET: your own wallet address to KYC and fund with USDG + ETH.
contract LocalDemo is Script {
    using stdStorage for StdStorage;
    using stdJson for string;

    address constant DELEGATE = 0xDe1e000000000000000000000000000000000001;
    address constant BORROWER = 0xb022000000000000000000000000000000000002;
    address constant LENDER = 0x1E2d000000000000000000000000000000000003;
    uint256 constant USD = 1e6;

    function run() external {
        require(block.chainid == 31337, "LocalDemo: local fork (31337) only");
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../deployments/31337.json"));
        address timelock = json.readAddress(".timelock");
        address officer = json.readAddress(".complianceOfficer");
        ComplianceRegistry compliance = ComplianceRegistry(json.readAddress(".complianceRegistry"));
        Underwriting underwriting = Underwriting(json.readAddress(".underwriting"));
        InvoiceNFT nft = InvoiceNFT(json.readAddress(".invoiceNFT"));
        PoolFactory factory = PoolFactory(json.readAddress(".poolFactory"));
        IERC20 usdg = IERC20(RobinhoodChain.USDG);
        address demoWallet = vm.envOr("DEMO_WALLET", address(0));

        // ---- node-level funding (anvil RPCs, not transactions)
        _setEth(DELEGATE);
        _setEth(BORROWER);
        _setEth(LENDER);
        _setEth(timelock);
        _setUsdg(DELEGATE, 100_000 * USD);
        _setUsdg(BORROWER, 50_000 * USD);
        _setUsdg(LENDER, 2_000_000 * USD);
        if (demoWallet != address(0)) {
            _setEth(demoWallet);
            _setUsdg(demoWallet, 1_000_000 * USD);
        }

        // ---- KYC (compliance officer)
        vm.startBroadcast(officer);
        compliance.setKyc(DELEGATE, type(uint64).max);
        compliance.setKyc(BORROWER, type(uint64).max);
        if (demoWallet != address(0)) compliance.setKyc(demoWallet, type(uint64).max);
        vm.stopBroadcast();

        // ---- governance actions (on mainnet these go through the 48h Timelock)
        vm.startBroadcast(timelock);
        underwriting.approveDelegate(DELEGATE, "ipfs://draftline-demo-delegate");
        if (demoWallet != address(0)) underwriting.approveDelegate(demoWallet, "ipfs://draftline-demo-wallet");
        PoolFactory.PoolAddresses memory a = factory.createPool(
            PoolFactory.CreatePoolArgs({
                asset: address(usdg),
                delegate: DELEGATE,
                name: "Demo Trade Receivables",
                symbol: "DEMO",
                epochDuration: 1 days,
                params: _params()
            })
        );
        vm.stopBroadcast();
        CreditPool pool = CreditPool(a.pool);

        // ---- delegate: first-loss cover + borrower approval
        vm.startBroadcast(DELEGATE);
        usdg.approve(a.firstLossVault, type(uint256).max);
        FirstLossVault(a.firstLossVault).deposit(60_000 * USD);
        pool.approveBorrower(BORROWER, 750_000 * USD);
        if (demoWallet != address(0)) pool.approveBorrower(demoWallet, 750_000 * USD);
        vm.stopBroadcast();

        // ---- lender: junior first, then senior up to the subordination cap
        vm.startBroadcast(LENDER);
        usdg.approve(a.juniorTranche, type(uint256).max);
        usdg.approve(a.seniorTranche, type(uint256).max);
        Tranche(a.juniorTranche).deposit(300_000 * USD, LENDER);
        Tranche(a.seniorTranche).deposit(1_000_000 * USD, LENDER);
        vm.stopBroadcast();

        // ---- borrower: two invoices, one funded, one awaiting the delegate
        vm.startBroadcast(BORROWER);
        uint256 id1 = nft.mint(
            uint128(250_000 * USD), uint64(block.timestamp + 60 days), keccak256("demo-debtor-1"), keccak256("INV-1001"), "bafkreidemoinvoice1001"
        );
        uint256 id2 = nft.mint(
            uint128(120_000 * USD), uint64(block.timestamp + 45 days), keccak256("demo-debtor-2"), keccak256("INV-1002"), "bafkreidemoinvoice1002"
        );
        nft.approve(address(pool), id1);
        nft.approve(address(pool), id2);
        pool.submitInvoice(id1);
        pool.submitInvoice(id2);
        vm.stopBroadcast();

        vm.broadcast(DELEGATE);
        pool.fundInvoice(id1, 200_000 * USD, 250, keccak256("demo-attestation-1001"));

        console2.log("Demo pool:", address(pool));
        console2.log("Delegate:", DELEGATE);
        console2.log("Borrower:", BORROWER);
        console2.log("Lender:", LENDER);
    }

    function _params() internal pure returns (PoolParams memory p) {
        p.advanceRateBps = 8_000;
        p.maxSeniorRatioBps = 8_000;
        p.seniorRateBps = 800;
        p.juniorHurdleBps = 1_400;
        p.protocolFeeBps = 1_000;
        p.delegateFeeBps = 1_000;
        p.minFirstLossBps = 500;
        p.lateFeeBps = 200;
        p.maxFeeBps = 1_000;
        p.maxBorrowerConcentrationBps = 4_000;
        p.maxActiveLoans = 100;
        p.gracePeriod = 5 days;
        p.defaultWindow = 30 days;
        p.maxTenor = 180 days;
        p.poolCap = uint128(10_000_000 * USD);
        p.minFirstLossAmount = uint128(25_000 * USD);
    }

    function _setEth(address who) internal {
        vm.rpc("anvil_setBalance", string.concat('["', vm.toString(who), '","0x56BC75E2D63100000"]'));
    }

    /// @dev Finds the USDG balance slot with forge-std's stdStorage, then writes it on the node.
    function _setUsdg(address who, uint256 amount) internal {
        uint256 slot = stdstore.target(RobinhoodChain.USDG).sig("balanceOf(address)").with_key(who).find();
        vm.rpc(
            "anvil_setStorageAt",
            string.concat(
                '["', vm.toString(RobinhoodChain.USDG), '","', vm.toString(bytes32(slot)), '","', vm.toString(bytes32(amount)), '"]'
            )
        );
        vm.store(RobinhoodChain.USDG, bytes32(slot), bytes32(amount)); // keep the local simulation in sync
    }
}
