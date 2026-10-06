// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SurfaceFixture} from "../utils/SurfaceFixture.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";
import {VolSurfaceOracle} from "../../src/oracle/VolSurfaceOracle.sol";

/// @notice Handler: the fixture contract itself builds reports (it owns the publisher keys), so it is the target;
///         the handler functions are prefixed `h_` and excluded from the invariant set by name.
contract VolSurfaceOracleInvariantTest is SurfaceFixture {
    // ghost model
    uint64 public ghostSeq;
    uint64 public ghostValidAfter;
    bytes32 public ghostRoot;
    uint256 public ghostIv;
    uint256 public badAccepts; // accepted with an ATM move > 20% outside emergency
    uint256 public accepted;
    uint256 public proven;
    Grid internal current;
    bool internal emergencyOn;

    function setUp() public {
        _deploySurface();
        bytes4[] memory sel = new bytes4[](4);
        sel[0] = this.h_submit.selector;
        sel[1] = this.h_prove.selector;
        sel[2] = this.h_emergency.selector;
        sel[3] = this.h_warp.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
        targetContract(address(this));
    }

    function h_submit(uint256 ivSeed, bool sameSeq) external {
        uint256 iv = bound(ivSeed, 0.2e18, 2e18);
        uint64 seq = sameSeq ? ghostSeq : ghostSeq + 1;
        uint64 va = uint64(block.timestamp);
        Grid memory g = _grid(va, iv);
        IVolSurfaceOracle.SurfaceReport memory r = _report(seq, va, g);
        bytes[] memory sigs = _sigs(r, _keysAB());
        try oracle.submitReport(r, sigs) {
            if (ghostSeq != 0 && !emergencyOn) {
                uint256 d = iv > ghostIv ? iv - ghostIv : ghostIv - iv;
                if (d * 10_000 > 2001 * ghostIv) badAccepts++;
            }
            (ghostSeq, ghostValidAfter, ghostRoot, ghostIv) = (seq, va, r.surfaceRoot, iv);
            _store(g);
            accepted++;
        } catch {}
    }

    function h_prove(uint8 i, uint8 j) external {
        if (ghostSeq == 0) return;
        i = uint8(bound(i, 0, N_TENORS - 1));
        j = uint8(bound(j, 0, N_NODES - 1));
        IVolSurfaceOracle.NodeProof[] memory n = new IVolSurfaceOracle.NodeProof[](1);
        n[0] = _nodeProof(ghostSeq, current, i, j);
        oracle.proveNodes(n); // must never fail for a leaf of the current report
        proven++;
    }

    function h_emergency(bool on) external {
        vm.prank(on ? guardian : governance);
        oracle.setEmergencyMode(ethUsdc, on);
        emergencyOn = on;
    }

    function h_warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 2 hours));
    }

    function _store(Grid memory g) internal {
        current.tenors = g.tenors;
        current.kNodes = g.kNodes;
        current.w = g.w;
    }

    // ------------------------------------------------------------------ invariants

    /// @dev INV-17: the stored header is the last accepted report; sequence and time never go back.
    function invariant_INV17_headerIsLastAccepted() public view {
        IVolSurfaceOracle.SurfaceHeader memory h = oracle.header(ethUsdc);
        assertEq(h.surfaceSeq, ghostSeq);
        assertEq(h.validAfter, ghostValidAfter);
        assertEq(h.surfaceRoot, ghostRoot);
    }

    /// @dev No report jumped more than maxIvMoveBps outside emergency mode.
    function invariant_ivMoveRespected() public view {
        assertEq(badAccepts, 0);
    }

    /// @dev INV-19: every proven leaf of the current report holds exactly the published value.
    function invariant_INV19_cachedLeavesExact() public view {
        if (ghostSeq == 0) return;
        for (uint256 i; i < N_TENORS; ++i) {
            for (uint256 j; j < N_NODES; ++j) {
                // forge-lint: disable-next-line(unsafe-typecast)
                (bool p, uint256 w) = oracle.nodeValue(ethUsdc, uint8(i), uint8(j));
                if (p) assertEq(w, current.w[i * N_NODES + j]);
            }
        }
    }

    /// @dev Status follows the age of the last report exactly (VOL-011, VOL-012).
    function invariant_statusMatchesAge() public view {
        (IVolSurfaceOracle.SurfaceStatus st, uint64 stale) = oracle.surfaceStatus(ethUsdc);
        if (ghostSeq == 0) {
            assertEq(uint8(st), uint8(IVolSurfaceOracle.SurfaceStatus.NONE));
            return;
        }
        uint256 age = block.timestamp - ghostValidAfter;
        IVolSurfaceOracle.SurfaceStatus expected = age > 21_600
            ? IVolSurfaceOracle.SurfaceStatus.EXPIRED_DATA
            : (age <= 300 ? IVolSurfaceOracle.SurfaceStatus.FRESH : IVolSurfaceOracle.SurfaceStatus.STALE);
        assertEq(uint8(st), uint8(expected));
        assertEq(stale, age > 300 ? age - 300 : 0);
    }

    function test_handlerPathsReachable() public {
        this.h_submit(0.6e18, false);
        this.h_prove(1, 2);
        this.h_warp(60);
        this.h_submit(1.5e18, false); // > 20% jump: rejected
        assertEq(accepted, 1);
        this.h_emergency(true);
        this.h_submit(1.5e18, false); // accepted in emergency mode
        assertEq(accepted, 2);
        this.h_prove(0, 0);
        assertEq(proven, 2);
        invariant_INV17_headerIsLastAccepted();
        invariant_INV19_cachedLeavesExact();
        invariant_statusMatchesAge();
    }
}
