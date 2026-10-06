// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SettlementOracleFixture} from "../utils/SettlementOracleFixture.sol";
import {ISettlementOracle} from "../../src/interfaces/ISettlementOracle.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {
    NotAuthorized,
    InvalidSettlementProof,
    FinalizationTooEarly,
    InvalidSettlementConfig,
    UnknownSettlementConfig,
    SettlementConfigExists
} from "../../src/libraries/Errors.sol";

/// @notice Unit tests for SettlementOracle: configs (STL-022) and the round-in-force rule (STL-001..STL-004).
contract SettlementOracleTest is SettlementOracleFixture {
    bytes32 internal cfgId;
    uint80 internal r1; // expiry − 10 min
    uint80 internal r2; // expiry − 30 s   ← in force at expiry
    uint80 internal r3; // expiry + 60 s

    function setUp() public {
        _deploySettlementOracle();
        cfgId = _register(_cfg(_direct(ethUsdcFeed), _direct(ethUsdcFallback), 0));
        r1 = ethUsdcFeed.pushRound(4100e8, EXPIRY - 600);
        r2 = ethUsdcFeed.pushRound(4200e8, EXPIRY - 30);
        r3 = ethUsdcFeed.pushRound(4300e8, EXPIRY + 60);
        vm.warp(EXPIRY + 300);
    }

    function _verify(bytes memory d) internal view returns (uint256 p, uint64 t, uint8 s) {
        return so.verify(cfgId, EXPIRY, d);
    }

    function _expectProof(uint8 reason, bytes memory d) internal {
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementProof.selector, reason));
        so.verify(cfgId, EXPIRY, d);
    }

    // ------------------------------------------------------------------ STL-022: configs

    function test_STL022_registerStoresImmutableApprovedConfig() public {
        ISettlementOracle.SettlementOracleConfig memory c = _cfg(_derived(), _none(), 120);
        bytes32 id = so.computeConfigId(c);
        vm.expectEmit(true, true, true, true, address(so));
        emit ISettlementOracle.SettlementConfigRegistered(id, c);
        vm.expectEmit(true, true, true, true, address(so));
        emit ISettlementOracle.SettlementConfigApproved(id, true);
        assertEq(_register(c), id);
        assertTrue(so.configExists(id));
        assertTrue(so.isConfigApproved(id));
        assertEq(keccak256(abi.encode(so.getConfig(id))), keccak256(abi.encode(c)));
        assertTrue(so.isConfigUsable(id, weth, usdcToken));
        assertFalse(so.isConfigUsable(id, usdcToken, weth), "pair must match");
        assertFalse(so.isConfigUsable(keccak256("x"), weth, usdcToken));

        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(SettlementConfigExists.selector, id));
        so.registerConfig(c);
    }

    function test_STL022_onlyOracleAdminRegisters() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, governance));
        so.registerConfig(_cfg(_derived(), _none(), 120));
    }

    function test_STL022_approval() public {
        vm.prank(guardian);
        so.setConfigApproved(cfgId, false);
        assertFalse(so.isConfigUsable(cfgId, weth, usdcToken));
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        so.setConfigApproved(cfgId, true);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        so.setConfigApproved(cfgId, false);
        vm.expectEmit(true, true, true, true, address(so));
        emit ISettlementOracle.SettlementConfigApproved(cfgId, true);
        vm.prank(governance);
        so.setConfigApproved(cfgId, true);
        assertTrue(so.isConfigUsable(cfgId, weth, usdcToken));

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UnknownSettlementConfig.selector, bytes32(uint256(1))));
        so.setConfigApproved(bytes32(uint256(1)), true);
        vm.expectRevert(abi.encodeWithSelector(UnknownSettlementConfig.selector, bytes32(uint256(1))));
        so.getConfig(bytes32(uint256(1)));
    }

    function test_STL022_configValidation() public {
        ISettlementOracle.SettlementOracleConfig memory c;

        c = _cfg(_direct(ethUsdcFeed), _none(), 0);
        c.underlying = address(0);
        _expectCfg(c, 1);
        c.underlying = usdcToken; // same as the settlement asset
        _expectCfg(c, 1);

        _expectCfg(_cfg(_none(), _none(), 0), 2);

        ISettlementOracle.FeedSource memory s = _direct(ethUsdcFeed);
        s.quoteFeed = address(usdcUsdFeed);
        _expectCfg(_cfg(s, _none(), 0), 3); // direct with a quote leg
        s = _none();
        s.feed = address(ethUsdcFeed);
        _expectCfg(_cfg(_direct(ethUsdcFeed), s, 0), 3); // no fallback but fallback fields set
        s = _derived();
        s.quoteFeed = s.feed;
        _expectCfg(_cfg(s, _none(), 60), 3); // derived with the same feed twice

        s = _direct(ethUsdcFeed);
        s.feed = stranger; // no code
        _expectCfg(_cfg(s, _none(), 0), 4);
        s = _direct(ethUsdcFeed);
        s.feedDecimals = 18; // decimals mismatch
        _expectCfg(_cfg(s, _none(), 0), 4);
        s.feedDecimals = 19;
        _expectCfg(_cfg(s, _none(), 0), 4);
        MockAggregator dead = new MockAggregator(8); // never updated
        _expectCfg(_cfg(_direct(dead), _none(), 0), 4);
        MockAggregator negative = new MockAggregator(8);
        negative.pushRound(-1, block.timestamp);
        _expectCfg(_cfg(_direct(negative), _none(), 0), 4);
        MockAggregator broken = _feed(1e8);
        broken.setBroken(true);
        _expectCfg(_cfg(_direct(broken), _none(), 0), 4);

        c = _cfg(_direct(ethUsdcFeed), _none(), 0);
        c.observationStartOffset = 1; // start after end
        _expectCfg(c, 5);
        c = _cfg(_direct(ethUsdcFeed), _none(), 0);
        c.observationStartOffset = -7 days - 1;
        _expectCfg(c, 5);
        c = _cfg(_direct(ethUsdcFeed), _none(), 0);
        c.observationEndOffset = 7 days + 1;
        _expectCfg(c, 5);
        c = _cfg(_direct(ethUsdcFeed), _none(), 0);
        c.minFinalizationDelay = c.maxFinalizationDelay + 1;
        _expectCfg(c, 5);
        c = _cfg(_direct(ethUsdcFeed), _none(), 0);
        c.maxFinalizationDelay = 90 days + 1;
        _expectCfg(c, 5);
        c = _cfg(_direct(ethUsdcFeed), _none(), 0);
        c.observationEndOffset = 3600;
        c.maxFinalizationDelay = 3600; // stalled before the observation ends
        c.minFinalizationDelay = 0;
        _expectCfg(c, 5);

        _expectCfg(_cfg(_direct(ethUsdcFeed), _none(), 60), 6); // skew without a derived source
        _expectCfg(_cfg(_derived(), _none(), 0), 6); // derived needs a skew bound
    }

    function _expectCfg(ISettlementOracle.SettlementOracleConfig memory c, uint8 reason) internal {
        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementConfig.selector, reason));
        so.registerConfig(c);
    }

    function test_windowViews() public view {
        assertEq(so.earliestFinalization(cfgId, EXPIRY), EXPIRY + 300);
        assertEq(so.stalledAfter(cfgId, EXPIRY), EXPIRY + 7 days);
    }

    // ------------------------------------------------------------------ STL-001: the round in force

    function test_STL001_inForceRoundWithSuccessor() public view {
        (uint256 p, uint64 t, uint8 src) = _verify(_data(0, _proof(r2, r3), _proof(0, 0)));
        assertEq(p, 4200e18);
        assertEq(t, EXPIRY - 30);
        assertEq(src, 0);
    }

    function test_STL001_inForceRoundIsLatest() public {
        MockAggregator f = _feed(4000e8);
        bytes32 id = _register(_cfg(_direct(f), _none(), 0));
        uint80 r = f.pushRound(4250e8, EXPIRY - 10);
        (uint256 p,,) = so.verify(id, EXPIRY, _data(0, _proof(r, 0), new ISettlementOracle.RoundProof[](0)));
        assertEq(p, 4250e18);
        // once a later round exists, "latest" no longer proves it, but the successor does
        uint80 later = f.pushRound(4300e8, EXPIRY + 5);
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementProof.selector, 3));
        so.verify(id, EXPIRY, _data(0, _proof(r, 0), new ISettlementOracle.RoundProof[](0)));
        (p,,) = so.verify(id, EXPIRY, _data(0, _proof(r, later), new ISettlementOracle.RoundProof[](0)));
        assertEq(p, 4250e18);
    }

    // ------------------------------------------------------------------ STL-002: wrong proofs

    function test_STL002_tooEarly() public {
        vm.warp(EXPIRY + 299);
        vm.expectRevert(abi.encodeWithSelector(FinalizationTooEarly.selector, EXPIRY + 300));
        _verify(_data(0, _proof(r2, r3), _proof(0, 0)));
    }

    function test_STL002_eachWrongProofRejected() public {
        _expectProof(6, _data(0, _proof(r1, r2), _proof(0, 0))); // an earlier round: its successor is not after T
        _expectProof(2, _data(0, _proof(r3, 0), _proof(0, 0))); // a round after T
        _expectProof(5, _data(0, _proof(r1, r3), _proof(0, 0))); // skipping a round
        _expectProof(3, _data(0, _proof(r2, 0), _proof(0, 0))); // claiming latest while r3 exists
        _expectProof(1, _data(0, _proof(0, 0), _proof(0, 0))); // round 0
        _expectProof(1, _data(0, _proof(r3 + 5, 0), _proof(0, 0))); // missing round
        _expectProof(4, _data(0, _proof(r2, r3 + 1), _proof(0, 0))); // missing successor
        _expectProof(11, _data(0, new ISettlementOracle.RoundProof[](2), _proof(0, 0)));
        _expectProof(12, _data(2, _proof(r2, r3), _proof(0, 0)));
    }

    function test_STL002_staleOrNonPositiveRoundIsInvalid() public {
        MockAggregator f = _feed(4000e8);
        bytes32 id = _register(_cfg(_direct(f), _none(), 0));
        uint80 old = f.pushRound(4000e8, EXPIRY - 3601); // in force, but before the window start
        uint80 after_ = f.pushRound(4000e8, EXPIRY + 1);
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementProof.selector, 7));
        so.verify(id, EXPIRY, _data(0, _proof(old, after_), new ISettlementOracle.RoundProof[](0)));

        MockAggregator g = _feed(4000e8);
        bytes32 gid = _register(_cfg(_direct(g), _none(), 0));
        uint80 neg = g.pushRound(0, EXPIRY - 5);
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementProof.selector, 7));
        so.verify(gid, EXPIRY, _data(0, _proof(neg, 0), new ISettlementOracle.RoundProof[](0)));
    }

    function test_STL002_feedReturningWrongRoundIsUnavailable() public {
        ethUsdcFeed.setReturnWrongId(true);
        _expectProof(1, _data(0, _proof(r2, r3), _proof(0, 0)));
    }

    function test_STL002_brokenLatestReadRejectsLatestClaim() public {
        MockAggregator f = _feed(4000e8);
        bytes32 id = _register(_cfg(_direct(f), _none(), 0));
        uint80 r = f.pushRound(4000e8, EXPIRY - 5);
        f.setLatestBroken(true);
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementProof.selector, 3));
        so.verify(id, EXPIRY, _data(0, _proof(r, 0), new ISettlementOracle.RoundProof[](0)));
    }

    // ------------------------------------------------------------------ STL-003: fallback only after proven failure

    function test_STL003_fallbackRules() public {
        uint80 f2 = ethUsdcFallback.pushRound(4190e8, EXPIRY - 20);
        uint80 f3 = ethUsdcFallback.pushRound(4195e8, EXPIRY + 20);
        // primary valid → fallback refused
        _expectProof(8, _data(1, _proof(r2, r3), _proof(f2, f3)));

        // make the primary's in-force round invalid (non-positive), then the fallback is allowed
        MockAggregator bad = _feed(4000e8);
        bytes32 id = _register(_cfg(_direct(bad), _direct(ethUsdcFallback), 0)); // live at registration
        uint80 b = bad.pushRound(-1, EXPIRY - 10);
        (uint256 p,, uint8 src) = so.verify(id, EXPIRY, _data(1, _proof(b, 0), _proof(f2, f3)));
        assertEq(p, 4190e18);
        assertEq(src, 1);
        // the primary alone can't settle
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementProof.selector, 7));
        so.verify(id, EXPIRY, _data(0, _proof(b, 0), _proof(f2, f3)));
        // an invalid fallback can't settle either
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementProof.selector, 6));
        so.verify(id, EXPIRY, _data(1, _proof(b, 0), _proof(1 << 64 | 1, f2)));
    }

    function test_STL003_noFallbackConfigured() public {
        MockAggregator f = _feed(4000e8);
        bytes32 id = _register(_cfg(_direct(f), _none(), 0));
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementProof.selector, 9));
        so.verify(id, EXPIRY, _data(1, _proof(1, 0), _proof(1, 0)));
    }

    function test_STL003_invalidFallbackObservation() public {
        MockAggregator bad = _feed(4000e8);
        MockAggregator fb = _feed(4000e8);
        bytes32 id = _register(_cfg(_direct(bad), _direct(fb), 0)); // both live at registration
        uint80 b = bad.pushRound(-1, EXPIRY - 10);
        uint80 stale = fb.pushRound(4000e8, EXPIRY - 7200); // before the window
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementProof.selector, 10));
        so.verify(id, EXPIRY, _data(1, _proof(b, 0), _proof(stale, 0)));
    }

    // ------------------------------------------------------------------ derived source

    function test_derivedPriceHalfUpAndLaterLegTime() public {
        bytes32 id = _register(_cfg(_derived(), _none(), 120));
        uint80 u = ethUsdFeed.pushRound(4000e8, EXPIRY - 50);
        uint80 q = usdcUsdFeed.pushRound(0.9998e8, EXPIRY - 10);
        ISettlementOracle.RoundProof[] memory p = new ISettlementOracle.RoundProof[](2);
        p[0] = ISettlementOracle.RoundProof(u, 0);
        p[1] = ISettlementOracle.RoundProof(q, 0);
        (uint256 price, uint64 t,) = so.verify(id, EXPIRY, _data(0, p, new ISettlementOracle.RoundProof[](0)));
        // 4000 / 0.9998 = 4000.80016003200640128025605121024204840968… → half-up at 18 decimals
        assertEq(price, 4000800160032006401280);
        assertEq(t, EXPIRY - 10);
    }

    function _derivedProofs(uint80 u, uint80 q) internal pure returns (ISettlementOracle.RoundProof[] memory p) {
        p = new ISettlementOracle.RoundProof[](2);
        p[0] = ISettlementOracle.RoundProof(u, 0);
        p[1] = ISettlementOracle.RoundProof(q, 0);
    }

    function test_derivedRoundsHalfUp() public {
        bytes32 id = _register(_cfg(_derived(), _none(), 120));
        uint80 u = ethUsdFeed.pushRound(2e8, EXPIRY - 50);
        uint80 q = usdcUsdFeed.pushRound(3e8, EXPIRY - 10);
        (uint256 price,,) = so.verify(id, EXPIRY, _data(0, _derivedProofs(u, q), new ISettlementOracle.RoundProof[](0)));
        assertEq(price, 666666666666666667); // 0.6666… rounded half up
    }

    function test_derivedPriceRoundingToZeroIsInvalid() public {
        bytes32 id = _register(_cfg(_derived(), _none(), 120));
        uint80 u = ethUsdFeed.pushRound(1, EXPIRY - 50); // 1e-8 USD
        uint80 q = usdcUsdFeed.pushRound(1e30, EXPIRY - 10); // absurdly large quote
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementProof.selector, 7));
        so.verify(id, EXPIRY, _data(0, _derivedProofs(u, q), new ISettlementOracle.RoundProof[](0)));
    }

    function test_derivedInvalidLegOrProofCount() public {
        bytes32 id = _register(_cfg(_derived(), _none(), 120));
        uint80 u = ethUsdFeed.pushRound(4000e8, EXPIRY - 50);
        uint80 q = usdcUsdFeed.pushRound(-1, EXPIRY - 10); // invalid quote leg
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementProof.selector, 7));
        so.verify(id, EXPIRY, _data(0, _derivedProofs(u, q), new ISettlementOracle.RoundProof[](0)));
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementProof.selector, 11));
        so.verify(id, EXPIRY, _data(0, _proof(u, 0), new ISettlementOracle.RoundProof[](0)));
    }

    function test_feedWithoutDecimalsRejected() public {
        ISettlementOracle.FeedSource memory s = _direct(ethUsdcFeed);
        s.feed = address(pc); // a contract with no decimals()
        _expectCfg(_cfg(s, _none(), 0), 4);
    }

    function test_derivedLegSkewTooLargeIsInvalid() public {
        bytes32 id = _register(_cfg(_derived(), _none(), 30));
        uint80 u = ethUsdFeed.pushRound(4000e8, EXPIRY - 50);
        uint80 q = usdcUsdFeed.pushRound(1e8, EXPIRY - 10); // 40 s apart > 30
        ISettlementOracle.RoundProof[] memory p = new ISettlementOracle.RoundProof[](2);
        p[0] = ISettlementOracle.RoundProof(u, 0);
        p[1] = ISettlementOracle.RoundProof(q, 0);
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementProof.selector, 7));
        so.verify(id, EXPIRY, _data(0, p, new ISettlementOracle.RoundProof[](0)));
    }

    // ------------------------------------------------------------------ Chainlink phases

    function test_phaseBoundarySuccessor() public {
        MockAggregator f = _feed(4000e8);
        bytes32 id = _register(_cfg(_direct(f), _none(), 0));
        uint80 last = f.pushRound(4210e8, EXPIRY - 5); // last round of phase 1
        f.startNewPhase();
        uint80 first = f.pushRound(4220e8, EXPIRY + 5); // phase 2, aggregator round 1
        assertTrue(so.isImmediateSuccessor(address(f), last, first));
        (uint256 p,,) = so.verify(id, EXPIRY, _data(0, _proof(last, first), new ISettlementOracle.RoundProof[](0)));
        assertEq(p, 4210e18);
    }

    function test_phaseJumpNotSuccessorIfRoundsRemain() public {
        MockAggregator f = _feed(4000e8);
        uint80 a = f.pushRound(4210e8, EXPIRY - 50);
        f.pushRound(4211e8, EXPIRY - 40); // a + 1 exists
        f.startNewPhase();
        uint80 first = f.pushRound(4220e8, EXPIRY + 5);
        assertFalse(so.isImmediateSuccessor(address(f), a, first));
        assertFalse(so.isImmediateSuccessor(address(f), a, first + 1), "aggregator round must be 1");
        assertFalse(so.isImmediateSuccessor(address(f), a, first + (uint80(1) << 64)), "phase must be +1");
        assertFalse(so.isImmediateSuccessor(address(f), type(uint80).max, uint80(1)), "no wrap");
        f.setZerosForMissing(true); // proxies that return zeros for missing rounds
        uint80 lastOfPhase = f.id(2, 1);
        f.startNewPhase();
        uint80 nextPhase = f.pushRound(4230e8, EXPIRY + 10);
        assertTrue(so.isImmediateSuccessor(address(f), lastOfPhase, nextPhase));
    }

    function test_normalizationOverflowIsInvalid() public {
        MockAggregator f = new MockAggregator(0);
        f.pushRound(1, EXPIRY - 1 days);
        ISettlementOracle.FeedSource memory s = _direct(f);
        s.feedDecimals = 0;
        bytes32 id = _register(_cfg(s, _none(), 0));
        uint80 r = f.pushRound(type(int256).max, EXPIRY - 5);
        vm.expectRevert(abi.encodeWithSelector(InvalidSettlementProof.selector, 7));
        so.verify(id, EXPIRY, _data(0, _proof(r, 0), new ISettlementOracle.RoundProof[](0)));
    }
}
