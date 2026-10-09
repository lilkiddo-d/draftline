// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {CreditPool} from "../../src/pool/CreditPool.sol";
import {LoanStatus} from "../../src/libraries/Types.sol";

contract CreditPoolFuzzTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _seedLiquidity();
    }

    function testFuzz_lifecycle_repay(uint256 advance, uint16 feeBps, uint32 elapsed, uint256 firstPayment) public {
        advance = bound(advance, 1 * USD, 400_000 * USD);
        feeBps = uint16(bound(feeBps, 0, 1_000));
        elapsed = uint32(bound(elapsed, 0, 200 days));
        uint256 id = _originate(advance * 2, advance, feeBps, 90 days);
        vm.warp(block.timestamp + elapsed);
        uint256 owed = d.lens.amountOwed(pool, id);
        firstPayment = bound(firstPayment, 1, owed);
        uint256 seniorBefore = pool.seniorAssets();
        _repay(borrower, id, firstPayment);
        _assertAccounting();
        if (pool.juniorAssets() > 200_000 * USD) assertEq(pool.seniorInterestOwed(), 0);
        uint256 rest = d.lens.amountOwed(pool, id);
        if (rest > 0) _repay(debtor, id, rest);
        assertEq(uint8(pool.getLoan(id).status), uint8(LoanStatus.Repaid));
        assertGe(pool.seniorAssets(), seniorBefore, "senior never loses on a repaid loan");
        assertEq(pool.outstandingPrincipal(), 0);
        _assertAccounting();
    }

    function testFuzz_default_lossOrder(uint256 advance, uint256 stake) public {
        stake = bound(stake, 0, 15_000 * USD);
        // shrink the delegate's stake to `stake` + 10k minimum (cover requirement: 5% of outstanding)
        vm.prank(delegate);
        flv.withdraw(40_000 * USD - stake, delegate);
        uint256 fl = flv.stake();
        advance = bound(advance, 1 * USD, fl * 20);
        uint256 id = _originate(advance * 2, advance, 100, 30 days);
        uint256 j = pool.juniorAssets();
        uint256 s = pool.seniorAssets();
        vm.prank(delegate);
        d.defaultManager.declareDefault(address(pool), id);
        uint256 flLoss = fl - flv.stake();
        uint256 jLoss = j - pool.juniorAssets();
        uint256 sLoss = s - pool.seniorAssets();
        assertEq(flLoss + jLoss + sLoss, advance);
        if (jLoss > 0) assertEq(flv.stake(), 0, "junior hit before first-loss exhausted");
        if (sLoss > 0) assertEq(pool.juniorAssets(), 0, "senior hit before junior exhausted");
        _assertAccounting();
    }

    function testFuzz_depositShares(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 * USD);
        uint256 shares = _deposit(carol, false, amount);
        assertEq(junior.convertToAssets(shares), amount);
        _assertAccounting();
    }
}
