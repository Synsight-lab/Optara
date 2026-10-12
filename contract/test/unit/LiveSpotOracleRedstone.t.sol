// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpotFixture} from "../utils/SpotFixture.sol";
import {ILiveSpotOracle} from "../../src/interfaces/ILiveSpotOracle.sol";
import {RedstonePayload} from "../../src/oracle/RedstonePayload.sol";
import {NotAuthorized, InvalidSpotSource, SpotConfidenceTooWide} from "../../src/libraries/Errors.sol";

/// @notice LiveSpotOracle's RedStone pull source: a real redstone-primary-prod payload (3 signers × MON, ETH, USDC,
///         fetched from RedStone's public gateway and encoded with RedStone's own protocol library) plus payloads
///         built here with test signers for the edge cases.
contract LiveSpotOracleRedstoneTest is SpotFixture {
    bytes internal constant REAL = hex"4d4f4e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000272d2001a13038c7f00000002000000166b1039e307b4dddd6c186ef8f657bd7e38a57633781e52a7dbfdb35fba6a969071f7c58be981441b216777247b6c35321045cd1b879e6dd4f652b2246b528031b4d4f4e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000272d2001a13038c7f0000000200000019e810f9e5a3cd1199f6244906188fada2ac4232ba80a802eb518eb651e17b3ac786a7af64ed0e0cb4ffe38008496261a80a0ae2fb1a4cf94431a2d1293a8e2c61c4d4f4e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000272d2001a13038c7f0000000200000017a0c3a17e4b4382bedd78ff368290949e91738732ed20cd1f1467680d59af29b3c2370111ed33ed9db14082a3bf54b618782e494b42a5e7da2695b5a97c74a931c45544800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003ae37f07bf01a13038c7f0000000200000018b1ec0db670b7999db7eb491af1a2b18800aabbef1422e97cb6c069aa3247c3c2fce00409399ed41f737fcedb37ad31ccd4ab28ab87adfbdd73168a954228de31c45544800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003ae395536901a13038c7f000000020000001c1da45f0f127c1621f882764b8d9f4c85bfe579e77d53fcd0987fd12434b4f25172e4e30014ed32c12e5c9fcf38a6433de6f9f33ef6da9ebf08766ff8a0f6af71c45544800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003ae3a523b401a13038c7f00000002000000141d9cabaf788453bcd9634b9e4bb84b5243f7844c6594a13b57b6b333a3f045e65c63231c3dc851c6de6719f27f243d30e2a8d8fe871eddf96f4f1902f7a68911b55534443000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005f59c7b01a13038c7f0000000200000011bd2f9560c8603bb189e608307ab902ed6440a13c1d0bab156f22dfc8671f6ce14c9e456939899c7c62ede565fa96108ca8b4c83294b69921b1edb5f71f8ced11c55534443000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005f5a22e01a13038c7f0000000200000014008f9e7e847e5ae501d16d7101f9fb3813fc7a6b810a179e5a7527b27b697e85b22fd4584627ff249f8c57a286e4ba74c984537a029d74034a4d1357c36d32e1b55534443000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005f5a42101a13038c7f000000020000001c96544b26092b84e7f0c85e93ecdf2e0c009b914265c54407495d045bd9725367ae66d2a2aa43031d19d86f91bb31235cf31e88f6820a706e5cf9f2e2a82c35e1b0009000000000002ed57011e0000";
    uint256 internal constant REAL_TS = 1_791_810_390; // its packages' timestamp (seconds)
    bytes32 internal constant RS_MON = bytes32("MON");
    bytes32 internal constant RS_ETH = bytes32("ETH");
    bytes32 internal constant RS_USDC = bytes32("USDC");

    function _primaryProdSigners() internal pure returns (address[] memory s) {
        s = new address[](5);
        s[0] = 0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774;
        s[1] = 0xdEB22f54738d54976C4c0fe5ce6d408E40d88499;
        s[2] = 0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202;
        s[3] = 0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE;
        s[4] = 0x9c5AE89C4Af6aA32cE58588DBaF90d18a855B6de;
    }

    function setUp() public {
        _deploySpot();
        vm.deal(address(this), 100 ether);
        vm.warp(REAL_TS + 5);
    }

    receive() external payable {}

    function _rsDerived(bytes32 base, bytes32 quote) internal pure returns (ILiveSpotOracle.SpotSource memory) {
        return ILiveSpotOracle.SpotSource({
            kind: ILiveSpotOracle.SourceKind.REDSTONE_DERIVED,
            baseFeedId: base,
            quoteFeedId: quote,
            maxSpotAge: 60,
            maxConfidenceBps: 100
        });
    }

    function _signers(address[] memory s, uint8 threshold) internal {
        vm.prank(governance);
        spot.setRedstoneSigners(s, threshold);
    }

    function _one(bytes memory p) internal pure returns (bytes[] memory u) {
        u = new bytes[](1);
        u[0] = p;
    }

    function _update(bytes[] memory u) internal returns (uint256) {
        bytes32[] memory products = new bytes32[](1);
        products[0] = ethUsdc;
        return spot.update{value: 1 ether}(u, products);
    }

    // ------------------------------------------------------------------ real RedStone data

    function test_realPayload_derivedPriceIsTheMedianRatio() public {
        _signers(_primaryProdSigners(), 3);
        vm.prank(governance);
        spot.setSource(ethUsdc, _rsDerived(RS_ETH, RS_USDC));
        assertEq(spot.updateFee(_one(REAL)), 0, "RedStone payloads cost no provider fee");
        _update(_one(REAL));

        // medians of the three signers: ETH 2529.26317417, USDC 0.99983918, MON 0.02567456 (8 decimals)
        (uint256 eth, uint64 t,) = spot.redstonePrice(RS_ETH);
        assertEq(eth, 2529.26317417e18);
        assertEq(t, REAL_TS);
        (uint256 usdc,, uint16 usdcSpread) = spot.redstonePrice(RS_USDC);
        assertEq(usdc, 0.99983918e18);
        assertEq(usdcSpread, 1); // (0.99984417 − 0.99982459) / median, rounded up
        (uint256 mon,, uint16 monSpread) = spot.redstonePrice(RS_MON);
        assertEq(mon, 0.02567456e18);
        assertEq(monSpread, 0);

        (uint256 price, uint64 publishTime) = spot.spotPrice(ethUsdc);
        assertEq(price, uint256(2529.26317417e18) * 1e18 / 0.99983918e18);
        assertEq(publishTime, REAL_TS);
        assertTrue(spot.isSpotFresh(ethUsdc));
    }

    function test_realPayload_needsThresholdDistinctAuthorizedSigners() public {
        _signers(_primaryProdSigners(), 4); // the payload carries 3 signers per feed
        vm.expectRevert(abi.encodeWithSelector(RedstonePayload.InvalidRedstonePayload.selector, 9));
        _update(_one(REAL));

        address[] memory others = new address[](3);
        others[0] = makeAddr("a");
        others[1] = makeAddr("b");
        others[2] = makeAddr("c");
        _signers(others, 1); // nobody in the payload is authorized
        vm.expectRevert(abi.encodeWithSelector(RedstonePayload.InvalidRedstonePayload.selector, 9));
        _update(_one(REAL));
    }

    function test_realPayload_tamperedValueLosesItsSigner() public {
        _signers(_primaryProdSigners(), 3);
        bytes memory bad = REAL;
        bad[63] = bytes1(uint8(bad[63]) ^ 1); // a value byte of the first package (RS_USDC)
        vm.expectRevert(abi.encodeWithSelector(RedstonePayload.InvalidRedstonePayload.selector, 9));
        _update(_one(bad));
    }

    function test_notConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(RedstonePayload.InvalidRedstonePayload.selector, 7));
        _update(_one(REAL));
    }

    // ------------------------------------------------------------------ built payloads (test signers)

    uint256[] internal keys;

    function _testSigners(uint256 n, uint8 threshold) internal {
        address[] memory s = new address[](n);
        delete keys;
        for (uint256 i; i < n; ++i) {
            keys.push(uint256(keccak256(abi.encode("redstone signer", i))) % (type(uint128).max) + 1);
            s[i] = vm.addr(keys[i]);
        }
        _signers(s, threshold);
    }

    /// @dev One RedStone package (one numeric data point, 32-byte value), signed by `key`.
    function _pkg(bytes32 feed, uint256 value8, uint256 tsMs, uint256 key) internal pure returns (bytes memory) {
        bytes memory signed = abi.encodePacked(feed, value8, uint48(tsMs), uint32(32), uint24(1));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(signed));
        return abi.encodePacked(signed, r, s, v);
    }

    function _payload(bytes[] memory pkgs) internal pure returns (bytes memory out) {
        for (uint256 i; i < pkgs.length; ++i) {
            out = abi.encodePacked(out, pkgs[i]);
        }
        out = abi.encodePacked(out, uint16(pkgs.length), uint24(0), RedstonePayload.MARKER);
    }

    function _three(bytes32 feed, uint256[3] memory v8, uint256 tsMs) internal view returns (bytes[] memory p) {
        p = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            p[i] = _pkg(feed, v8[i], tsMs, keys[i]);
        }
    }

    function _direct(bytes32 feed, uint16 maxConfBps) internal pure returns (ILiveSpotOracle.SpotSource memory s) {
        s = ILiveSpotOracle.SpotSource({
            kind: ILiveSpotOracle.SourceKind.REDSTONE_DIRECT,
            baseFeedId: feed,
            quoteFeedId: 0,
            maxSpotAge: 60,
            maxConfidenceBps: maxConfBps
        });
    }

    function test_medianSpreadAndConfidenceLimit() public {
        _testSigners(3, 2);
        vm.prank(governance);
        spot.setSource(ethUsdc, _direct(RS_ETH, 50));
        uint256 ts = block.timestamp * 1000;
        // 2500, 2510, 2600: median 2510, spread (2600 − 2500) / 2510 = 3.98% → 399 bps > 50
        bytes[] memory u = _one(_payload(_three(RS_ETH, [uint256(2500e8), 2510e8, 2600e8], ts)));
        vm.expectRevert(abi.encodeWithSelector(SpotConfidenceTooWide.selector, ethUsdc, 399));
        _update(u);

        vm.prank(governance);
        spot.setSource(ethUsdc, _direct(RS_ETH, 500));
        _update(u);
        (uint256 price,) = spot.spotPrice(ethUsdc);
        assertEq(price, 2510e18);
    }

    function test_duplicateSignerCountsOnce_andTimestampsMustMatch() public {
        _testSigners(3, 2);
        vm.prank(governance);
        spot.setSource(ethUsdc, _direct(RS_ETH, 500));
        uint256 ts = block.timestamp * 1000;
        bytes[] memory p = new bytes[](2);
        p[0] = _pkg(RS_ETH, 2500e8, ts, keys[0]);
        p[1] = _pkg(RS_ETH, 2500e8, ts, keys[0]); // same signer twice
        vm.expectRevert(abi.encodeWithSelector(RedstonePayload.InvalidRedstonePayload.selector, 9));
        _update(_one(_payload(p)));

        p[1] = _pkg(RS_ETH, 2500e8, ts - 1000, keys[1]); // another signer, another timestamp
        vm.expectRevert(abi.encodeWithSelector(RedstonePayload.InvalidRedstonePayload.selector, 8));
        _update(_one(_payload(p)));
    }

    function test_neverReplacedByAnOlderPrice_andFutureRejected() public {
        _testSigners(3, 2);
        vm.prank(governance);
        spot.setSource(ethUsdc, _direct(RS_ETH, 500));
        uint256 ts = block.timestamp * 1000;
        _update(_one(_payload(_three(RS_ETH, [uint256(2500e8), 2500e8, 2500e8], ts))));
        _update(_one(_payload(_three(RS_ETH, [uint256(9999e8), 9999e8, 9999e8], ts - 30_000)))); // older: ignored
        (uint256 price,) = spot.spotPrice(ethUsdc);
        assertEq(price, 2500e18);

        vm.expectRevert(abi.encodeWithSelector(RedstonePayload.InvalidRedstonePayload.selector, 10));
        _update(_one(_payload(_three(RS_ETH, [uint256(2500e8), 2500e8, 2500e8], ts + 61_000))));
    }

    function test_pythAndRedstoneInOneUpdate_feeOnlyForPyth() public {
        _testSigners(3, 2);
        uint256 ts = block.timestamp * 1000;
        bytes[] memory u = new bytes[](3);
        u[0] = _upd(ETH_USD, 2500e8, block.timestamp); // the fixture's product is Pyth-derived: both legs
        u[1] = _payload(_three(RS_MON, [uint256(0.0256e8), 0.0256e8, 0.0256e8], ts));
        u[2] = _upd(USDC_USD, 1e8, block.timestamp);
        bytes[] memory pythOnly = new bytes[](2);
        pythOnly[0] = u[0];
        pythOnly[1] = u[2];
        assertEq(spot.updateFee(u), spot.updateFee(pythOnly));
        assertGt(spot.updateFee(u), 0);
        _update(u);
        (uint256 mon,,) = spot.redstonePrice(RS_MON);
        assertEq(mon, 0.0256e18);
        (uint256 price,) = spot.spotPrice(ethUsdc);
        assertEq(price, 2500e18); // the Pyth product still updates
    }

    function test_setRedstoneSigners_validation() public {
        address[] memory s = new address[](2);
        s[0] = makeAddr("s0");
        s[1] = makeAddr("s1");
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        spot.setRedstoneSigners(s, 1);

        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotSource.selector, 6));
        spot.setRedstoneSigners(s, 3); // threshold above the set
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotSource.selector, 6));
        spot.setRedstoneSigners(s, 0);
        s[1] = s[0];
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotSource.selector, 6));
        spot.setRedstoneSigners(s, 1); // duplicate
        s[1] = address(0);
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotSource.selector, 6));
        spot.setRedstoneSigners(s, 1); // zero address

        s[1] = makeAddr("s1");
        spot.setRedstoneSigners(s, 2);
        (address[] memory got, uint8 t) = spot.redstoneSigners();
        assertEq(got.length, 2);
        assertEq(t, 2);
        // replacing the set clears the old signers
        address[] memory s2 = new address[](1);
        s2[0] = makeAddr("s2");
        spot.setRedstoneSigners(s2, 1);
        (got, t) = spot.redstoneSigners();
        assertEq(got.length, 1);
        assertEq(got[0], s2[0]);
        vm.stopPrank();
    }

    function test_setSource_acceptsRedstoneKinds() public {
        vm.startPrank(governance);
        spot.setSource(ethUsdc, _direct(RS_ETH, 100));
        assertEq(uint8(spot.sourceOf(ethUsdc).kind), uint8(ILiveSpotOracle.SourceKind.REDSTONE_DIRECT));
        ILiveSpotOracle.SpotSource memory s = _rsDerived(RS_ETH, RS_ETH);
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotSource.selector, 3)); // legs must differ
        spot.setSource(ethUsdc, s);
        vm.stopPrank();
    }
}
