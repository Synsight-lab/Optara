// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SurfaceFixture} from "../utils/SurfaceFixture.sol";
import {MerkleHelper} from "../utils/MerkleHelper.sol";
import {VolSurfaceOracle} from "../../src/oracle/VolSurfaceOracle.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IOptionSeriesRegistry} from "../../src/interfaces/IOptionSeriesRegistry.sol";
import {
    NotAuthorized,
    ZeroAddress,
    InvalidSurfaceReport,
    InvalidSignatures,
    InvalidSurfaceConfig,
    InvalidPublisher
} from "../../src/libraries/Errors.sol";

/// @notice Unit tests for VolSurfaceOracle: VOL-001..VOL-014.
contract VolSurfaceOracleTest is SurfaceFixture {
    Grid internal g;
    IVolSurfaceOracle.SurfaceReport internal r1;

    function setUp() public {
        _deploySurface();
        g = _grid(T0, 0.6e18);
        r1 = _report(1, T0, g);
    }

    function _expect(IVolSurfaceOracle.SurfaceReport memory r, uint8 reason) internal {
        bytes[] memory sigs = _sigs(r, _keysAB());
        vm.expectRevert(abi.encodeWithSelector(InvalidSurfaceReport.selector, reason));
        oracle.submitReport(r, sigs);
    }

    // ------------------------------------------------------------------ initialization

    function test_initializeChecks() public {
        address impl = address(new VolSurfaceOracle());
        vm.startPrank(governance);
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.deployProxy(
            impl,
            abi.encodeCall(
                VolSurfaceOracle.initialize, (IProtocolControl(address(pc)), IOptionSeriesRegistry(address(0)), 2)
            )
        );
        vm.expectRevert(abi.encodeWithSelector(InvalidSurfaceConfig.selector, 10));
        upgradeAdmin.deployProxy(
            impl,
            abi.encodeCall(
                VolSurfaceOracle.initialize,
                (IProtocolControl(address(pc)), IOptionSeriesRegistry(address(registry)), 0)
            )
        );
        vm.stopPrank();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(IProtocolControl(address(pc)), IOptionSeriesRegistry(address(registry)), 2);
        assertEq(oracle.quorum(), 2);
        assertEq(oracle.registry(), address(registry));
    }

    // ------------------------------------------------------------------ VOL-001: accept

    function test_VOL001_acceptedWithQuorum() public {
        vm.expectEmit(true, true, true, true, address(oracle));
        emit IVolSurfaceOracle.SurfaceAccepted(ethUsdc, 1, r1.surfaceRoot, T0, T0 + 900, 300, false);
        _submit(r1);
        IVolSurfaceOracle.SurfaceHeader memory h = oracle.header(ethUsdc);
        assertEq(h.surfaceSeq, 1);
        assertEq(h.surfaceRoot, r1.surfaceRoot);
        assertEq(h.validAfter, T0);
        assertEq(h.tenorTimestamps[1], T0 + 30 days);
        assertEq(h.atmTotalVarianceByTenor[2], r1.atmTotalVarianceByTenor[2]);
        assertFalse(h.lowConfidence);
        assertEq(oracle.kNodes(ethUsdc).length, N_NODES);
        assertEq(h.kNodesHash, keccak256(abi.encodePacked(g.kNodes)));
        (IVolSurfaceOracle.SurfaceStatus st,) = oracle.surfaceStatus(ethUsdc);
        assertEq(uint8(st), uint8(IVolSurfaceOracle.SurfaceStatus.FRESH));
    }

    // ------------------------------------------------------------------ VOL-002: domain and product

    function test_VOL002_domainAndProduct() public {
        IVolSurfaceOracle.SurfaceReport memory r = r1;
        r.chainId = 1;
        _expect(r, 1);
        r = r1;
        r.verifyingContract = address(registry);
        _expect(r, 1);
        r = r1;
        r.productId = keccak256("BTC/USDC");
        _expect(r, 2);
        r = r1;
        r.underlying = makeAddr("WBTC"); // pair doesn't match the product
        _expect(r, 2);
    }

    function test_VOL002_productWithoutConfigRejected() public {
        address wbtc = makeAddr("WBTC");
        vm.prank(governance);
        bytes32 btc = registry.approveProduct(wbtc, address(usdc), _ethConfig());
        IVolSurfaceOracle.SurfaceReport memory r = r1;
        (r.productId, r.underlying) = (btc, wbtc);
        _expect(r, 2);
    }

    // ------------------------------------------------------------------ VOL-003: replay and order

    function test_VOL003_noReplayNoGoingBack() public {
        _submit(r1);
        _expect(r1, 3); // replay
        vm.warp(T0 + 10);
        IVolSurfaceOracle.SurfaceReport memory r = _report(1, T0 + 10, _grid(T0 + 10, 0.6e18));
        _expect(r, 3); // same seq
        r = _report(2, T0 - 1, _grid(T0 - 1, 0.6e18)); // newer seq, older time
        _expect(r, 3);
        r = _report(2, T0 + 10, _grid(T0 + 10, 0.6e18));
        _submit(r);
        assertEq(oracle.header(ethUsdc).surfaceSeq, 2);
    }

    // ------------------------------------------------------------------ VOL-004: validity window

    function test_VOL004_validityWindow() public {
        IVolSurfaceOracle.SurfaceReport memory r = _report(1, T0 + 1, _grid(T0 + 1, 0.6e18));
        _expect(r, 4); // not yet valid
        vm.warp(T0 + 900);
        _expect(r1, 4); // now == expiresAt
        vm.warp(T0);
        r = r1;
        r.expiresAt = T0 + 901; // lifetime above 900
        _expect(r, 4);
    }

    // ------------------------------------------------------------------ VOL-005: signatures

    function test_VOL005_signatureRules() public {
        uint256[] memory k = new uint256[](1);
        k[0] = keyA;
        bytes[] memory sigs = _sigs(r1, k);
        vm.expectRevert(InvalidSignatures.selector); // below quorum
        oracle.submitReport(r1, sigs);

        sigs = new bytes[](2);
        (sigs[0], sigs[1]) = (_sign(r1, keyA), _sign(r1, keyA));
        vm.expectRevert(InvalidSignatures.selector); // duplicate signer
        oracle.submitReport(r1, sigs);

        sigs = _sigs(r1, _keysAB());
        (sigs[0], sigs[1]) = (sigs[1], sigs[0]);
        vm.expectRevert(InvalidSignatures.selector); // not sorted by signer
        oracle.submitReport(r1, sigs);

        (, uint256 strangerKey) = makeAddrAndKey("not a publisher");
        k = new uint256[](2);
        (k[0], k[1]) = (keyA, strangerKey);
        sigs = _sigs(r1, k);
        vm.expectRevert(InvalidSignatures.selector); // unknown signer
        oracle.submitReport(r1, sigs);

        sigs = _sigs(r1, _keysAB());
        sigs[0] = hex"1234";
        vm.expectRevert(InvalidSignatures.selector); // malformed
        oracle.submitReport(r1, sigs);
    }

    function test_VOL005_marketMakersAloneCannotPublish() public {
        (address mm2, uint256 mm2Key) = makeAddrAndKey("market maker 2");
        vm.prank(governance);
        oracle.addPublisher(mm2, false);
        uint256[] memory k = new uint256[](2);
        (k[0], k[1]) = (keyB, mm2Key);
        bytes[] memory sigs = _sigs(r1, k);
        vm.expectRevert(InvalidSignatures.selector);
        oracle.submitReport(r1, sigs);
    }

    function test_VOL005_signatureBindsTheReport() public {
        bytes[] memory sigs = _sigs(r1, _keysAB());
        IVolSurfaceOracle.SurfaceReport memory r = r1;
        r.confidenceBps = 301; // any change after signing
        vm.expectRevert(InvalidSignatures.selector);
        oracle.submitReport(r, sigs);
    }

    function test_VOL005_moreThanQuorumIsFine() public {
        uint256[] memory k = new uint256[](3);
        (k[0], k[1], k[2]) = (keyA, keyB, keyC);
        oracle.submitReport(r1, _sigs(r1, k));
        assertEq(oracle.header(ethUsdc).surfaceSeq, 1);
    }

    // ------------------------------------------------------------------ VOL-006: grid sanity

    function test_VOL006_tenorAndCalendarChecks() public {
        IVolSurfaceOracle.SurfaceReport memory r = r1;
        (r.atmTotalVarianceByTenor[1], r.atmTotalVarianceByTenor[2]) =
        (r.atmTotalVarianceByTenor[2], r.atmTotalVarianceByTenor[1]); // variance decreasing in tenor
        _expect(r, 5);
        r = r1;
        (r.tenorTimestamps[1], r.tenorTimestamps[2]) = (r.tenorTimestamps[2], r.tenorTimestamps[1]);
        _expect(r, 5); // tenors not increasing
        r = r1;
        r.tenorTimestamps = [uint64(0), 0, 0, 0];
        r.atmTotalVarianceByTenor = [uint256(0), 0, 0, 0];
        _expect(r, 5); // no tenor
        r = r1;
        r.tenorTimestamps[3] = T0 + 200 days; // a 4th tenor with zero ATM variance
        _expect(r, 5);
        r = r1;
        r.atmTotalVarianceByTenor[3] = 1; // variance on an unused tenor
        _expect(r, 5);
        r = r1;
        r.tenorTimestamps[0] = T0; // tenor not after validAfter
        _expect(r, 5);
        r = r1;
        r.atmTotalVarianceByTenor[0] = 0;
        _expect(r, 5);
        r = r1;
        r.surfaceMaxIvBps = 5000; // ATM IV 60% above the report's own max
        _expect(r, 5);
    }

    function test_VOL006_kNodeChecks() public {
        IVolSurfaceOracle.SurfaceReport memory r = r1;
        r.kNodes = new int256[](0);
        _expect(r, 6);
        r.kNodes = new int256[](33);
        for (uint256 i; i < 33; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            r.kNodes[i] = int256(i);
        }
        _expect(r, 6);
        r.kNodes = new int256[](2);
        (r.kNodes[0], r.kNodes[1]) = (0, 0);
        _expect(r, 6);
    }

    function test_ivBoundsVsProduct() public {
        IVolSurfaceOracle.SurfaceReport memory r = r1;
        r.surfaceMinIvBps = 999; // below the 10% floor
        _expect(r, 7);
        r = r1;
        r.surfaceMaxIvBps = 50_001; // above the 500% cap
        _expect(r, 7);
        r = r1;
        (r.surfaceMinIvBps, r.surfaceMaxIvBps) = (20_000, 10_000);
        _expect(r, 7);
    }

    // ------------------------------------------------------------------ VOL-007: IV move and emergency mode

    function test_VOL007_ivMoveLimitAndEmergency() public {
        _submit(r1);
        vm.warp(T0 + 60);
        // +19% ATM IV: accepted
        Grid memory up = _grid(T0 + 60, 0.714e18);
        _submit(_report(2, T0 + 60, up));
        // +21% from 71.4%: rejected
        vm.warp(T0 + 120);
        IVolSurfaceOracle.SurfaceReport memory big = _report(3, T0 + 120, _grid(T0 + 120, 0.864e18));
        _expect(big, 8);

        vm.expectEmit(true, true, true, true, address(oracle));
        emit IVolSurfaceOracle.EmergencyModeSet(ethUsdc, true);
        vm.prank(guardian);
        oracle.setEmergencyMode(ethUsdc, true);
        assertTrue(oracle.isEmergency(ethUsdc));
        _submit(big); // waived in emergency mode
        assertEq(oracle.header(ethUsdc).surfaceSeq, 3);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        oracle.setEmergencyMode(ethUsdc, false);
        vm.prank(governance);
        oracle.setEmergencyMode(ethUsdc, false);
        assertFalse(oracle.isEmergency(ethUsdc));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        oracle.setEmergencyMode(ethUsdc, true);
    }

    function test_VOL007_ivMoveComparedAtSameExpiry() public {
        _submit(r1);
        // a later report whose tenors fall between and beyond the stored ones, same 60% smile: no move
        vm.warp(T0 + 3 days);
        Grid memory g2 = _grid(T0 + 3 days, 0.6e18); // tenors T0+10d, +33d, +93d
        _submit(_report(2, T0 + 3 days, g2));
    }

    // ------------------------------------------------------------------ VOL-008: confidence

    function test_VOL008_lowConfidenceStoredAndFlagged() public {
        IVolSurfaceOracle.SurfaceReport memory r = r1;
        r.confidenceBps = 1001;
        vm.expectEmit(true, true, true, true, address(oracle));
        emit IVolSurfaceOracle.SurfaceAccepted(ethUsdc, 1, r.surfaceRoot, T0, T0 + 900, 1001, true);
        _submit(r);
        assertTrue(oracle.header(ethUsdc).lowConfidence);
        vm.warp(T0 + 30);
        _submit(_report(2, T0 + 30, _grid(T0 + 30, 0.6e18)));
        assertFalse(oracle.header(ethUsdc).lowConfidence, "a confident report clears it");
    }

    // ------------------------------------------------------------------ VOL-009 / VOL-013: leaves

    function test_VOL009_proveAndCache() public {
        _submit(r1);
        IVolSurfaceOracle.NodeProof[] memory n = new IVolSurfaceOracle.NodeProof[](2);
        n[0] = _nodeProof(1, g, 0, 1);
        n[1] = _nodeProof(1, g, 2, 4);
        (bool proven,) = oracle.nodeValue(ethUsdc, 0, 1);
        assertFalse(proven, "VOL-013: not proven yet");
        vm.expectEmit(true, true, true, true, address(oracle));
        emit IVolSurfaceOracle.NodeProven(ethUsdc, 1, 0, 1, g.w[1]);
        oracle.proveNodes(n);
        uint256 w;
        (proven, w) = oracle.nodeValue(ethUsdc, 0, 1);
        assertTrue(proven);
        assertEq(w, g.w[1]);
        (proven, w) = oracle.nodeValue(ethUsdc, 2, 4);
        assertEq(w, g.w[14]);

        vm.recordLogs();
        oracle.proveNodes(n); // already proven: skipped
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_VOL009_badProofsRejected() public {
        _submit(r1);
        IVolSurfaceOracle.NodeProof[] memory n = new IVolSurfaceOracle.NodeProof[](1);
        n[0] = _nodeProof(1, g, 1, 2);
        n[0].totalVarianceWad += 1; // tampered value
        vm.expectRevert(abi.encodeWithSelector(InvalidSurfaceReport.selector, 10));
        oracle.proveNodes(n);

        n[0] = _nodeProof(1, g, 1, 2);
        n[0].nodeIndex = 3; // proof for another leaf
        vm.expectRevert(abi.encodeWithSelector(InvalidSurfaceReport.selector, 10));
        oracle.proveNodes(n);

        n[0] = _nodeProof(1, g, 1, 2);
        n[0].tenorIndex = 3; // unused tenor
        vm.expectRevert(abi.encodeWithSelector(InvalidSurfaceReport.selector, 10));
        oracle.proveNodes(n);

        n[0] = _nodeProof(1, g, 1, 2);
        n[0].nodeIndex = 5; // beyond kNodes
        vm.expectRevert(abi.encodeWithSelector(InvalidSurfaceReport.selector, 10));
        oracle.proveNodes(n);

        n[0] = _nodeProof(1, g, 1, 2);
        n[0].surfaceSeq = 0;
        vm.expectRevert(abi.encodeWithSelector(InvalidSurfaceReport.selector, 10));
        oracle.proveNodes(n);
    }

    function test_VOL009_leavesOfOldReportsCannotBeProved() public {
        _submit(r1);
        vm.warp(T0 + 30);
        _submit(_report(2, T0 + 30, _grid(T0 + 30, 0.6e18)));
        IVolSurfaceOracle.NodeProof[] memory n = new IVolSurfaceOracle.NodeProof[](1);
        n[0] = _nodeProof(1, g, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(InvalidSurfaceReport.selector, 10));
        oracle.proveNodes(n);
    }

    function test_VOL009_leafIvOutsideReportBoundsRejected() public {
        Grid memory bad = _grid(T0, 0.6e18);
        bad.w[N_NODES * 1 + 4] = bad.w[N_NODES * 1 + 4] * 40; // σ ≈ 506% at the edge: above 300%
        IVolSurfaceOracle.SurfaceReport memory r = _report(1, T0, bad);
        _submit(r); // the header is fine (ATM leaves are normal)
        IVolSurfaceOracle.NodeProof[] memory n = new IVolSurfaceOracle.NodeProof[](1);
        n[0] = _nodeProof(1, bad, 1, 4);
        vm.expectRevert(abi.encodeWithSelector(InvalidSurfaceReport.selector, 9));
        oracle.proveNodes(n);
    }

    // ------------------------------------------------------------------ VOL-011 / VOL-012: staleness

    function test_VOL011_statusOverTime() public {
        (IVolSurfaceOracle.SurfaceStatus st, uint64 stale) = oracle.surfaceStatus(ethUsdc);
        assertEq(uint8(st), uint8(IVolSurfaceOracle.SurfaceStatus.NONE));
        _submit(r1);
        vm.warp(T0 + 300);
        (st, stale) = oracle.surfaceStatus(ethUsdc);
        assertEq(uint8(st), uint8(IVolSurfaceOracle.SurfaceStatus.FRESH));
        vm.warp(T0 + 301);
        (st, stale) = oracle.surfaceStatus(ethUsdc);
        assertEq(uint8(st), uint8(IVolSurfaceOracle.SurfaceStatus.STALE));
        assertEq(stale, 1);
        vm.warp(T0 + 21_600);
        (st, stale) = oracle.surfaceStatus(ethUsdc);
        assertEq(uint8(st), uint8(IVolSurfaceOracle.SurfaceStatus.STALE));
        assertEq(stale, 21_300);
        vm.warp(T0 + 21_601);
        (st,) = oracle.surfaceStatus(ethUsdc);
        assertEq(uint8(st), uint8(IVolSurfaceOracle.SurfaceStatus.EXPIRED_DATA), "VOL-012");
    }

    function test_VOL011_reportExpiryEndsFreshness() public {
        vm.prank(governance);
        IVolSurfaceOracle.SurfaceConfig memory c = _surfaceConfig();
        c.maxReportLifetime = 900;
        c.surfaceStaleAfter = 1000; // longer than the report lifetime
        c.maxLongTimeValueStale = 1800;
        oracle.setSurfaceConfig(ethUsdc, c);
        _submit(r1);
        vm.warp(T0 + 900); // age 900 ≤ 1000 but the report expired
        (IVolSurfaceOracle.SurfaceStatus st, uint64 stale) = oracle.surfaceStatus(ethUsdc);
        assertEq(uint8(st), uint8(IVolSurfaceOracle.SurfaceStatus.STALE));
        assertEq(stale, 0);
    }

    // ------------------------------------------------------------------ VOL-014: publishers and config

    function test_VOL014_publishers() public {
        address p = makeAddr("newPublisher");
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        oracle.addPublisher(p, true);
        vm.startPrank(governance);
        vm.expectEmit(true, true, true, true, address(oracle));
        emit IVolSurfaceOracle.PublisherAdded(p, true);
        oracle.addPublisher(p, true);
        vm.expectRevert(abi.encodeWithSelector(InvalidPublisher.selector, p));
        oracle.addPublisher(p, true);
        vm.expectRevert(abi.encodeWithSelector(InvalidPublisher.selector, address(0)));
        oracle.addPublisher(address(0), true);
        vm.stopPrank();
        (bool active, bool independent) = oracle.isPublisher(p);
        assertTrue(active && independent);

        vm.expectEmit(true, true, true, true, address(oracle));
        emit IVolSurfaceOracle.PublisherRemoved(pubA);
        vm.prank(guardian); // removing is instant for the guardian
        oracle.removePublisher(pubA);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(InvalidPublisher.selector, pubA));
        oracle.removePublisher(pubA);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        oracle.removePublisher(pubC);

        // A's signature no longer counts
        bytes[] memory sigs = _sigs(r1, _keysAB());
        vm.expectRevert(InvalidSignatures.selector);
        oracle.submitReport(r1, sigs);
    }

    function test_VOL014_quorum() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        oracle.setQuorum(3);
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(InvalidSurfaceConfig.selector, 10));
        oracle.setQuorum(0);
        vm.expectEmit(true, true, true, true, address(oracle));
        emit IVolSurfaceOracle.QuorumSet(3);
        oracle.setQuorum(3);
        vm.stopPrank();
        bytes[] memory sigs = _sigs(r1, _keysAB());
        vm.expectRevert(InvalidSignatures.selector);
        oracle.submitReport(r1, sigs);
    }

    function test_surfaceConfigValidation() public {
        IVolSurfaceOracle.SurfaceConfig memory c;
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(InvalidSurfaceConfig.selector, 1));
        oracle.setSurfaceConfig(keccak256("unknown"), _surfaceConfig());
        c = _surfaceConfig();
        c.maxReportLifetime = 0;
        _cfg(c, 2);
        c.maxReportLifetime = 1 days + 1;
        _cfg(c, 2);
        c = _surfaceConfig();
        c.maxIvMoveBps = 0;
        _cfg(c, 3);
        c = _surfaceConfig();
        c.maxConfidenceBps = 10_001;
        _cfg(c, 3);
        c = _surfaceConfig();
        c.minIvBps = 0;
        _cfg(c, 4);
        c = _surfaceConfig();
        c.minIvBps = c.maxIvBps;
        _cfg(c, 4);
        c = _surfaceConfig();
        c.maxIvBps = 100_001;
        _cfg(c, 4);
        c = _surfaceConfig();
        c.surfaceStaleAfter = 0;
        _cfg(c, 5);
        c = _surfaceConfig();
        c.maxSurfaceStale = c.surfaceStaleAfter - 1;
        _cfg(c, 5);
        c = _surfaceConfig();
        c.maxLongTimeValueStale = c.surfaceStaleAfter - 1;
        _cfg(c, 5);
        c = _surfaceConfig();
        c.maxLongTimeValueStale = c.maxSurfaceStale + 1;
        _cfg(c, 5);
        c = _surfaceConfig();
        c.staleIvPenaltyBpsPerHour = 100_001;
        _cfg(c, 6);
        vm.expectEmit(true, true, true, true, address(oracle));
        emit IVolSurfaceOracle.SurfaceConfigSet(ethUsdc, _surfaceConfig());
        oracle.setSurfaceConfig(ethUsdc, _surfaceConfig());
        vm.stopPrank();
        assertEq(oracle.surfaceConfig(ethUsdc).maxSurfaceStale, 21_600);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        oracle.setSurfaceConfig(ethUsdc, _surfaceConfig());
    }

    function _cfg(IVolSurfaceOracle.SurfaceConfig memory c, uint8 reason) internal {
        vm.expectRevert(abi.encodeWithSelector(InvalidSurfaceConfig.selector, reason));
        oracle.setSurfaceConfig(ethUsdc, c);
    }

    // ------------------------------------------------------------------ kNodes storage

    function test_kNodesStoredOnlyWhenChanged() public {
        _submit(r1);
        vm.warp(T0 + 30);
        IVolSurfaceOracle.SurfaceReport memory r2 = _report(2, T0 + 30, _grid(T0 + 30, 0.6e18));
        bytes[] memory s2 = _sigs(r2, _keysAB());
        vm.record();
        oracle.submitReport(r2, s2);
        (, bytes32[] memory writesSame) = vm.accesses(address(oracle));

        vm.warp(T0 + 60);
        Grid memory g3 = _grid(T0 + 60, 0.6e18);
        g3.kNodes[0] = -1.1e18; // grid changed
        IVolSurfaceOracle.SurfaceReport memory r3 = _report(3, T0 + 60, g3);
        bytes[] memory s3 = _sigs(r3, _keysAB());
        vm.record();
        oracle.submitReport(r3, s3);
        (, bytes32[] memory writesChanged) = vm.accesses(address(oracle));

        assertEq(oracle.kNodes(ethUsdc)[0], -1.1e18);
        // the changed grid rewrites the array (5 elements + length); the unchanged one writes none of it
        assertEq(writesChanged.length, writesSame.length + N_NODES + 1);
    }
}
