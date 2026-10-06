// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SettlementOracleFixture} from "../utils/SettlementOracleFixture.sol";
import {ISettlementOracle} from "../../src/interfaces/ISettlementOracle.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

/// @notice The caller can't choose the settlement price (ORACLES.md §5.2): for any round history, exactly one
///         (round, successor) proof is accepted, and it is the last round with updatedAt ≤ expiry.
contract SettlementOracleFuzzTest is SettlementOracleFixture {
    function setUp() public {
        _deploySettlementOracle();
    }

    function testFuzz_STL001_exactlyOneRoundProvable(uint256 seed, uint8 n, bool newPhaseMidway) public {
        n = uint8(bound(n, 1, 12));
        MockAggregator f = _feed(4000e8);
        bytes32 id = _register(_cfg(_direct(f), _none(), 0));

        uint80[] memory ids = new uint80[](n + 1);
        uint256[] memory times = new uint256[](n + 1);
        ids[0] = f.latestId();
        times[0] = EXPIRY - 1 days;
        uint256 t = EXPIRY - 3000;
        for (uint256 i = 1; i <= n; ++i) {
            t += 1 + uint256(keccak256(abi.encode(seed, i))) % 900; // strictly increasing, around expiry
            if (newPhaseMidway && i == n / 2 + 1) f.startNewPhase();
            // forge-lint: disable-next-line(unsafe-typecast)
            ids[i] = f.pushRound(int256(4000e8 + i * 1e8), t); // i ≤ 12
            times[i] = t;
        }
        vm.warp(t > EXPIRY + 300 ? t + 1 : EXPIRY + 301);

        // the expected in-force round: last with updatedAt ≤ expiry
        uint256 inForce;
        for (uint256 i; i <= n; ++i) {
            if (times[i] <= EXPIRY) inForce = i;
        }

        uint256 accepted;
        for (uint256 i; i <= n; ++i) {
            uint80 next = i < n ? ids[i + 1] : 0;
            bytes memory d = _data(0, _proof(ids[i], next), new ISettlementOracle.RoundProof[](0));
            try so.verify(id, EXPIRY, d) returns (uint256 price, uint64 obs, uint8) {
                accepted++;
                assertEq(i, inForce, "only the in-force round is provable");
                assertEq(obs, times[i]);
                assertEq(price, (4000 + i) * 1e18);
            } catch {}
        }
        // the in-force round is always provable when it is inside the observation window (fresh enough)
        bool fresh = times[inForce] >= EXPIRY - 3600;
        assertEq(accepted, fresh ? 1 : 0);
    }
}
