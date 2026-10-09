// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Waterfall} from "../../src/libraries/Waterfall.sol";

contract WaterfallFuzzTest is Test {
    uint256 constant MAX = 1e30;

    function testFuzz_income_conservesAndPrioritisesSenior(
        uint256 amount,
        uint256 seniorOwed,
        uint256 juniorOwed,
        uint16 pBps,
        uint16 dBps
    ) public pure {
        amount = bound(amount, 0, MAX);
        seniorOwed = bound(seniorOwed, 0, MAX);
        juniorOwed = bound(juniorOwed, 0, MAX);
        pBps = uint16(bound(pBps, 0, 5_000));
        dBps = uint16(bound(dBps, 0, 5_000 - pBps));
        Waterfall.IncomeSplit memory s = Waterfall.distributeIncome(amount, seniorOwed, juniorOwed, pBps, dBps);

        assertEq(s.senior + s.juniorHurdle + s.juniorResidual + s.protocol + s.delegate, amount, "conservation");
        assertLe(s.senior, seniorOwed);
        assertLe(s.juniorHurdle, juniorOwed);
        // Junior (hurdle or residual) is never paid unless senior interest is fully current.
        if (s.juniorHurdle + s.juniorResidual > 0) assertEq(s.senior, seniorOwed, "junior before senior");
        // Protocol fee is paid last: only once both senior and the junior hurdle are current.
        if (s.protocol + s.delegate > 0) {
            assertEq(s.senior, seniorOwed);
            assertEq(s.juniorHurdle, juniorOwed);
        }
    }

    function testFuzz_loss_firstLossThenJuniorThenSenior(uint256 loss, uint256 fl, uint256 jr, uint256 sr)
        public
        pure
    {
        loss = bound(loss, 0, MAX);
        fl = bound(fl, 0, MAX);
        jr = bound(jr, 0, MAX);
        sr = bound(sr, 0, MAX);
        Waterfall.LossSplit memory s = Waterfall.allocateLoss(loss, fl, jr, sr);
        assertEq(s.firstLoss + s.junior + s.senior + s.uncovered, loss, "conservation");
        assertLe(s.firstLoss, fl);
        assertLe(s.junior, jr);
        assertLe(s.senior, sr);
        if (s.junior > 0) assertEq(s.firstLoss, fl, "junior hit before first-loss exhausted");
        if (s.senior > 0) assertEq(s.junior, jr, "senior hit before junior exhausted");
        if (s.uncovered > 0) assertEq(s.senior, sr);
    }

    function testFuzz_recovery_order(uint256 amount, uint256 sWd, uint256 sInt, uint256 jWd, uint256 fWd)
        public
        pure
    {
        amount = bound(amount, 0, MAX);
        sWd = bound(sWd, 0, MAX);
        sInt = bound(sInt, 0, MAX);
        jWd = bound(jWd, 0, MAX);
        fWd = bound(fWd, 0, MAX);
        Waterfall.RecoverySplit memory s = Waterfall.allocateRecovery(amount, sWd, sInt, jWd, fWd);
        assertEq(s.senior + s.seniorInterest + s.junior + s.firstLoss + s.excess, amount, "conservation");
        if (s.seniorInterest > 0) assertEq(s.senior, sWd);
        if (s.junior > 0) assertEq(s.seniorInterest, sInt, "junior before senior interest");
        if (s.firstLoss > 0) assertEq(s.junior, jWd);
        if (s.excess > 0) assertEq(s.firstLoss, fWd);
    }
}
