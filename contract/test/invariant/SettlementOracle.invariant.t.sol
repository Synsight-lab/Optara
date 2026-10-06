// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SettlementOracleFixture} from "../utils/SettlementOracleFixture.sol";
import {SettlementOracle} from "../../src/oracle/SettlementOracle.sol";
import {ISettlementOracle} from "../../src/interfaces/ISettlementOracle.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

/// @notice Rounds keep arriving (sometimes across a phase change) while time moves. Once the round in force at
///         expiry is provable, the proven price must never change, whatever is appended later.
contract SettlementHandler is Test {
    SettlementOracle internal so;
    MockAggregator internal feed;
    bytes32 internal cfgId;
    uint64 internal expiry;

    uint80 public lastId;
    uint256 public lastTime;
    uint80 public inForceId; // last round with updatedAt ≤ expiry
    uint80 public successorId; // first round after expiry
    uint256 public inForceAnswer;
    bool public locked; // price observed once
    uint256 public lockedPrice;
    uint256 public rounds;

    constructor(SettlementOracle s, MockAggregator f, bytes32 id, uint64 e) {
        (so, feed, cfgId, expiry) = (s, f, id, e);
        lastId = f.latestId();
        lastTime = block.timestamp - 1;
    }

    function pushRound(uint32 dt, uint64 answer, bool newPhase) external {
        // a Chainlink round is stamped with the block time it is written in: never in the past
        uint256 base = lastTime + 1 > block.timestamp ? lastTime + 1 : block.timestamp;
        uint256 t = base + bound(dt, 0, 1200);
        vm.warp(t);
        if (newPhase) feed.startNewPhase();
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 a = int256(uint256(bound(answer, 1, 1e12)));
        uint80 id = feed.pushRound(a, t);
        if (t <= expiry) {
            inForceId = id;
            // forge-lint: disable-next-line(unsafe-typecast)
            inForceAnswer = uint256(a) * 1e10;
        } else if (successorId == 0) {
            successorId = id;
        }
        (lastId, lastTime) = (id, t);
        rounds++;
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3600));
    }

    /// @dev Tries the canonical proof; records the first price seen.
    function observe() external {
        if (inForceId == 0) return;
        bytes memory d = abi.encode(
            ISettlementOracle.SettlementData(0, _proof(inForceId, successorId), new ISettlementOracle.RoundProof[](0))
        );
        try so.verify(cfgId, expiry, d) returns (uint256 p, uint64, uint8) {
            if (!locked) (locked, lockedPrice) = (true, p);
            assertEq(p, lockedPrice, "settlement price changed");
            assertEq(p, inForceAnswer);
        } catch {}
    }

    function _proof(uint80 r, uint80 n) internal pure returns (ISettlementOracle.RoundProof[] memory p) {
        p = new ISettlementOracle.RoundProof[](1);
        p[0] = ISettlementOracle.RoundProof(r, n);
    }
}

contract SettlementOracleInvariantTest is SettlementOracleFixture {
    SettlementHandler internal handler;
    bytes32 internal cfgId;
    bytes32 internal cfgHash;

    function setUp() public {
        _deploySettlementOracle();
        cfgId = _register(_cfg(_direct(ethUsdcFeed), _none(), 0));
        cfgHash = keccak256(abi.encode(so.getConfig(cfgId)));
        vm.warp(EXPIRY - 50 minutes);
        handler = new SettlementHandler(so, ethUsdcFeed, cfgId, EXPIRY);
        targetContract(address(handler));
    }

    /// @dev Configs are immutable.
    function invariant_configNeverChanges() public view {
        assertEq(keccak256(abi.encode(so.getConfig(cfgId))), cfgHash);
    }

    /// @dev Once seen, the settlement price is fixed (checked inside the handler on every observe).
    function invariant_lockedPriceIsInForceAnswer() public view {
        if (handler.locked()) assertEq(handler.lockedPrice(), handler.inForceAnswer());
    }

    function test_handlerPathsReachable() public {
        handler.pushRound(600, 4100e8, false); // before expiry
        handler.pushRound(900, 4200e8, false); // still before
        handler.pushRound(6000, 4300e8, true); // after expiry, new phase
        handler.warp(3600);
        handler.observe();
        assertTrue(handler.locked());
        handler.pushRound(10, 9999e8, false);
        handler.observe();
        assertEq(handler.lockedPrice(), handler.inForceAnswer());
    }
}
