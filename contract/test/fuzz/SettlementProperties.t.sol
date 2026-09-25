// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";
import {MathHarness} from "../utils/MathHarness.sol";

/// @notice Property fuzzing for TEST_CASES.md RSK-016..019 (margin monotonicity), ASY-005 (order independence of
///         asynchronous settlement) and VLT-008 (exact vault identity under arbitrary interleavings).
contract SettlementPropertiesTest is OptaraTestBase {
    MathHarness math;
    bytes32 k10;
    bytes32 k12;
    bytes32 p10;
    bytes32 grp;

    function setUp() public override {
        super.setUp();
        math = new MathHarness();
        k10 = _monCall(10 * WAD, 5 * WAD);
        k12 = _monCall(12 * WAD, 3 * WAD);
        p10 = _monPut(10 * WAD, 4 * WAD);
        grp = _groupOf(k10);
    }

    // =============================================================================================
    // RSK-016..019: W is monotone in each short and each locked-long quantity (MATH.md sections 75, 34-36)
    // =============================================================================================

    /// Random bounded group of 1..6 legs mixing calls/puts, strikes, caps, contract sizes and quantities.
    function _legs(uint256 seed, uint256 n) internal pure returns (Leg[] memory legs) {
        legs = new Leg[](n);
        uint256[3] memory sizes = [uint256(1e18), 5e17, 1e17];
        for (uint256 i = 0; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bool isCall = r & 1 == 0;
            uint256 k = (1 + (r >> 8) % 40) * 1e18 + ((r >> 16) % 4) * 25e16;
            uint256 c = (1 + (r >> 24) % 20) * 5e17;
            if (!isCall && c > k) c = k; // put cap <= strike (OPTION_SPEC.md section 12)
            legs[i] = Leg(
                isCall ? OptionType.CALL : OptionType.PUT,
                k,
                c,
                sizes[(r >> 32) % 3],
                (r >> 40) % 5e18,
                (r >> 104) % 5e18
            );
        }
    }

    function _copy(Leg[] memory a) internal pure returns (Leg[] memory b) {
        b = new Leg[](a.length);
        for (uint256 i = 0; i < a.length; ++i) {
            b[i] =
                Leg(a[i].optionType, a[i].strikeWad, a[i].capWad, a[i].contractSizeWad, a[i].shortQty, a[i].lockedQty);
        }
    }

    function _append(Leg[] memory a, Leg memory extra) internal pure returns (Leg[] memory b) {
        b = new Leg[](a.length + 1);
        for (uint256 i = 0; i < a.length; ++i) {
            b[i] = a[i];
        }
        b[a.length] = extra;
    }

    function testFuzz_RSK_016_addShortMonotonicity(uint256 seed, uint256 n, uint256 idx, uint256 delta) public view {
        n = bound(n, 1, 6);
        idx = bound(idx, 0, n - 1);
        delta = bound(delta, 1, 5e18);
        Leg[] memory legs = _legs(seed, n);
        uint256 w = math.worstCaseLossNumerator(legs);
        Leg[] memory more = _copy(legs);
        more[idx].shortQty += delta;
        assertGe(math.worstCaseLossNumerator(more), w, "more short on an existing leg");
        assertGe(math.marginNative(more, 6), math.marginNative(legs, 6));
        // a brand-new short leg (new series in the group) cannot lower W either
        Leg memory fresh = _legs(seed ^ 0xabc, 1)[0];
        fresh.lockedQty = 0;
        fresh.shortQty = delta;
        assertGe(math.worstCaseLossNumerator(_append(legs, fresh)), w, "new short leg");
    }

    function testFuzz_RSK_017_closeShortMonotonicity(uint256 seed, uint256 n, uint256 idx, uint256 delta) public view {
        n = bound(n, 1, 6);
        idx = bound(idx, 0, n - 1);
        Leg[] memory legs = _legs(seed, n);
        vm.assume(legs[idx].shortQty > 0);
        delta = bound(delta, 1, legs[idx].shortQty);
        uint256 w = math.worstCaseLossNumerator(legs);
        Leg[] memory less = _copy(legs);
        less[idx].shortQty -= delta;
        assertLe(math.worstCaseLossNumerator(less), w, "EXTERNAL close");
        // a LOCKED close removes the same quantity from both legs of the identical series: W unchanged
        Leg[] memory both = _copy(legs);
        uint256 m = delta < both[idx].lockedQty ? delta : both[idx].lockedQty;
        both[idx].shortQty -= m;
        both[idx].lockedQty -= m;
        assertEq(math.worstCaseLossNumerator(both), w, "LOCKED close leaves W unchanged");
    }

    function testFuzz_RSK_018_addLockedLongMonotonicity(uint256 seed, uint256 n, uint256 idx, uint256 delta)
        public
        view
    {
        n = bound(n, 1, 6);
        idx = bound(idx, 0, n - 1);
        delta = bound(delta, 1, 5e18);
        Leg[] memory legs = _legs(seed, n);
        uint256 w = math.worstCaseLossNumerator(legs);
        Leg[] memory more = _copy(legs);
        more[idx].lockedQty += delta;
        assertLe(math.worstCaseLossNumerator(more), w, "more hedge on an existing leg");
        Leg memory fresh = _legs(seed ^ 0xdef, 1)[0];
        fresh.shortQty = 0;
        fresh.lockedQty = delta;
        assertLe(math.worstCaseLossNumerator(_append(legs, fresh)), w, "new locked leg");
    }

    function testFuzz_RSK_019_removeLockedLongMonotonicity(uint256 seed, uint256 n, uint256 idx, uint256 delta)
        public
        view
    {
        n = bound(n, 1, 6);
        idx = bound(idx, 0, n - 1);
        Leg[] memory legs = _legs(seed, n);
        vm.assume(legs[idx].lockedQty > 0);
        delta = bound(delta, 1, legs[idx].lockedQty);
        uint256 w = math.worstCaseLossNumerator(legs);
        Leg[] memory less = _copy(legs);
        less[idx].lockedQty -= delta;
        assertGe(math.worstCaseLossNumerator(less), w, "unlock");
        assertGe(math.marginNative(less, 18), math.marginNative(legs, 18));
    }

    /// The same monotonicity through the deployed core's own previews (requiredMarginAfter uses the enforcement path).
    function testFuzz_RSK_016_019_coreRequiredMarginAfter(uint256 q, uint256 dq) public {
        q = bound(q, 1e15, 3e18);
        dq = bound(dq, 1, q);
        _deposit(alice, usdt, 100e6);
        _deposit(carol, usdt, 100e6);
        vm.prank(carol);
        core.write(k12, q, alice);
        _lock(alice, k12, q);
        vm.prank(alice);
        core.write(k10, q, alice);
        uint256 now_ = core.requiredMargin(alice, address(usdt));
        int256 d = int256(dq);
        assertGe(core.requiredMarginAfter(alice, k10, d, 0), now_, "RSK-016");
        assertLe(core.requiredMarginAfter(alice, k10, -d, 0), now_, "RSK-017");
        assertLe(core.requiredMarginAfter(alice, k12, 0, d), now_, "RSK-018");
        assertGe(core.requiredMarginAfter(alice, k12, 0, -d), now_, "RSK-019");
    }

    // =============================================================================================
    // ASY-005: any permutation of redemptions and writer syncs yields the same economic state
    // =============================================================================================

    struct Outcome {
        uint256 aliceCash;
        uint256 carolCash;
        uint256 bobUsdt;
        uint256 daveUsdt;
        uint256 vault;
        uint256 residualN;
        uint256 supply10;
        uint256 supply12;
    }

    function _asySetup(uint256 priceWad) internal {
        _deposit(alice, usdt, 5e6);
        _deposit(carol, usdt, 5e6);
        vm.prank(alice);
        core.write(k10, WAD, bob);
        vm.prank(carol);
        core.write(k10, WAD / 3, dave);
        vm.prank(carol);
        core.write(k12, WAD, alice);
        _lock(alice, k12, WAD);
        _finalizeMon(k10, priceWad);
    }

    function _step(uint256 step) internal {
        if (step == 0) {
            vm.prank(bob);
            core.redeem(k10, WAD, bob);
        } else if (step == 1) {
            vm.prank(dave);
            core.redeem(k10, WAD / 3, dave);
        } else if (step == 2) {
            core.syncRiskGroup(alice, grp);
        } else {
            core.syncRiskGroup(carol, grp);
        }
    }

    function _outcome() internal view returns (Outcome memory o) {
        o = Outcome(
            core.cashBalance(alice, address(usdt)),
            core.cashBalance(carol, address(usdt)),
            usdt.balanceOf(bob),
            usdt.balanceOf(dave),
            usdt.balanceOf(address(core)),
            core.roundingResidualN(address(usdt)),
            _token(k10).totalSupply(),
            _token(k12).totalSupply()
        );
    }

    function testFuzz_ASY_005_arbitraryPermutationProperty(uint256 priceSeed, uint256 permSeed) public {
        // any representable 8-decimal feed price from 0.00000001 to 30 USDT per MON
        uint256 priceWad = bound(priceSeed, 1, 30e8) * 1e10;
        _asySetup(priceWad);
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < 4; ++i) {
            _step(i);
        }
        Outcome memory ref = _outcome();
        vm.revertToState(snap);

        uint256[4] memory order = [uint256(0), 1, 2, 3];
        for (uint256 i = 3; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(permSeed, i))) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }
        for (uint256 i = 0; i < 4; ++i) {
            _step(order[i]);
        }
        Outcome memory got = _outcome();
        assertEq(got.aliceCash, ref.aliceCash, "alice");
        assertEq(got.carolCash, ref.carolCash, "carol");
        assertEq(got.bobUsdt, ref.bobUsdt, "bob");
        assertEq(got.daveUsdt, ref.daveUsdt, "dave");
        assertEq(got.vault, ref.vault, "vault");
        assertEq(got.residualN, ref.residualN, "rounding reserve");
        assertEq(got.supply10, 0);
        assertEq(got.supply12, 0);
    }

    // =============================================================================================
    // VLT-008: the exact pooled identity holds after every step of an arbitrary interleaving
    // =============================================================================================

    function testFuzz_VLT_008_interleavingSettlementIdentity(uint256 priceSeed, uint256 actionSeed) public {
        address[] memory accts = new address[](4);
        (accts[0], accts[1], accts[2], accts[3]) = (alice, bob, carol, dave);
        bytes32[] memory ids = new bytes32[](3);
        (ids[0], ids[1], ids[2]) = (k10, k12, p10);

        _deposit(alice, usdt, 20e6);
        _deposit(carol, usdt, 20e6);
        vm.startPrank(alice);
        core.write(k10, WAD / 3, bob);
        core.write(p10, 2 * WAD / 7, dave);
        vm.stopPrank();
        vm.prank(carol);
        core.write(k12, 5 * WAD / 9, alice);
        _lock(alice, k12, WAD / 9);
        assertEq(_protocolOwnedN(address(usdt), accts, ids), 0, "before settlement");
        _finalizeMon(k10, bound(priceSeed, 1, 30e8) * 1e10);
        assertEq(_protocolOwnedN(address(usdt), accts, ids), 0, "at finalization");

        for (uint256 i = 0; i < 12; ++i) {
            uint256 r = uint256(keccak256(abi.encode(actionSeed, i)));
            uint256 action = r % 7;
            address who = accts[(r >> 8) % 4];
            bytes32 id = ids[(r >> 16) % 3];
            if (action == 0 || action == 1) {
                uint256 bal = _token(id).balanceOf(who);
                if (bal > 0) {
                    uint256 q = 1 + (r >> 24) % bal;
                    vm.prank(who);
                    core.redeem(id, q, who);
                }
            } else if (action == 2) {
                core.syncRiskGroup(who, grp);
            } else if (action == 3) {
                core.syncAccount(who, address(usdt));
            } else if (action == 4) {
                uint256 free = core.freeCollateral(who, address(usdt));
                if (free > 0) {
                    vm.prank(who);
                    core.withdraw(address(usdt), 1 + (r >> 24) % free, who);
                }
            } else if (action == 5) {
                _deposit(who, usdt, 1 + (r >> 24) % 3e6);
            } else {
                _fund(who, usdt, 1e6);
                vm.prank(who);
                core.recapitalize(address(usdt), 1 + (r >> 24) % 1e6);
            }
            assertEq(_protocolOwnedN(address(usdt), accts, ids), 0, "exact identity after each step");
        }
    }
}
