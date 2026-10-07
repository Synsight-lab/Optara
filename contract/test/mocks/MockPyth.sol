// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPyth} from "../../src/interfaces/IPyth.sol";

/// @notice Pyth stand-in (TESTING.md §4 MockSpotSource). Behaves like Pyth where it matters to Optara:
///         a fee per update, prices only replaced by newer publish times, unknown feeds revert.
///         An update is `abi.encode(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime)`.
contract MockPyth is IPyth {
    uint256 public feePerUpdate = 1;
    mapping(bytes32 => Price) internal prices;

    error PriceFeedNotFound();
    error InsufficientFee();

    function setFeePerUpdate(uint256 f) external {
        feePerUpdate = f;
    }

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256) {
        return updateData.length * feePerUpdate;
    }

    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        if (msg.value < updateData.length * feePerUpdate) revert InsufficientFee();
        for (uint256 i; i < updateData.length; ++i) {
            (bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) =
                abi.decode(updateData[i], (bytes32, int64, uint64, int32, uint256));
            if (publishTime > prices[id].publishTime) prices[id] = Price(price, conf, expo, publishTime);
        }
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory p) {
        p = prices[id];
        if (p.publishTime == 0) revert PriceFeedNotFound();
    }

    function encode(bytes32 id, int64 price, int32 expo, uint256 publishTime) external pure returns (bytes memory) {
        return abi.encode(id, price, uint64(0), expo, publishTime);
    }

    function encodeWithConf(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(id, price, conf, expo, publishTime);
    }
}

/// @notice A caller that cannot receive native refunds.
contract RefundRejecter {
    function forward(address target, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}
