// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title RedstonePayload
/// @notice Parses and authenticates a RedStone "pull" payload (the bytes RedStone's SDK builds from signed data
///         packages) passed as an argument, rather than appended to calldata as RedStone's own consumer contracts
///         expect. Layout, read from the end:
///           marker (9 bytes, 0x000002ed57011e0000) | metadata size (3) | metadata | packages count (2) | packages
///         and each package, also read from its end:
///           signature r‖s‖v (65) | data points count (3) | value byte size (4) | timestamp ms (6) | data points
///         where a data point is feed id (32) ‖ value (value byte size, big-endian, 8 decimals for numeric feeds).
///         The signer signs keccak256 of everything in the package except the signature (no message prefix).
/// @dev Checked against live redstone-primary-prod payloads: every package recovers to an authorized signer.
library RedstonePayload {
    bytes9 internal constant MARKER = 0x000002ed57011e0000;
    uint256 internal constant MAX_POINTS = 64; // per payload, across packages
    uint256 internal constant MAX_VALUE_BYTES = 32;

    struct Point {
        bytes32 feedId;
        uint256 value;
        uint64 timestampMs;
        address signer;
    }

    error InvalidRedstonePayload(uint8 reason);

    uint8 internal constant P_LENGTH = 1;
    uint8 internal constant P_MARKER = 2;
    uint8 internal constant P_VALUE_SIZE = 3;
    uint8 internal constant P_TOO_MANY = 4;
    uint8 internal constant P_SIGNATURE = 5;
    uint8 internal constant P_TRAILING = 6;

    /// @notice True if `data` ends with RedStone's payload marker.
    function isRedstone(bytes calldata data) internal pure returns (bool) {
        return data.length >= 9 && bytes9(data[data.length - 9:]) == MARKER;
    }

    /// @notice Every data point of every package, each with the signer recovered from its package's signature
    ///         (address(0) if the signature is invalid). Reverts on a malformed payload.
    function parse(bytes calldata data) internal pure returns (Point[] memory points) {
        if (!isRedstone(data)) revert InvalidRedstonePayload(P_MARKER);
        uint256 end = data.length - 9;
        if (end < 3) revert InvalidRedstonePayload(P_LENGTH);
        uint256 metaSize = _uint(data, end - 3, 3);
        if (end < 3 + metaSize + 2) revert InvalidRedstonePayload(P_LENGTH);
        end -= 3 + metaSize;
        uint256 packages = _uint(data, end - 2, 2);
        end -= 2;

        Point[] memory buf = new Point[](MAX_POINTS);
        uint256 n;
        for (uint256 i; i < packages; ++i) {
            (end, n) = _package(data, end, buf, n);
        }
        if (end != 0) revert InvalidRedstonePayload(P_TRAILING);
        assembly {
            mstore(buf, n) // shrink to the points read
        }
        return buf;
    }

    /// @dev Reads the package ending at `end` into `buf` from index `n`; returns where it starts and the new count.
    function _package(bytes calldata data, uint256 end, Point[] memory buf, uint256 n)
        private
        pure
        returns (uint256 start, uint256 count)
    {
        if (end < 65 + 13) revert InvalidRedstonePayload(P_LENGTH);
        uint256 sigStart = end - 65;
        uint256 points = _uint(data, sigStart - 3, 3);
        uint256 valueSize = _uint(data, sigStart - 7, 4);
        if (valueSize == 0 || valueSize > MAX_VALUE_BYTES) revert InvalidRedstonePayload(P_VALUE_SIZE);
        if (sigStart < 13 + points * (32 + valueSize)) revert InvalidRedstonePayload(P_LENGTH);
        start = sigStart - 13 - points * (32 + valueSize);
        count = n + points;
        if (count > MAX_POINTS) revert InvalidRedstonePayload(P_TOO_MANY);
        Point memory proto = Point({
            feedId: 0,
            value: 0,
            timestampMs: uint64(_uint(data, sigStart - 13, 6)),
            signer: _recover(keccak256(data[start:sigStart]), data[sigStart:end])
        });
        for (uint256 j; j < points; ++j) {
            buf[n + j] = _point(data, start + j * (32 + valueSize), valueSize, proto);
        }
    }

    /// @dev The data point at `p`, with the package's timestamp and signer from `proto`.
    function _point(bytes calldata data, uint256 p, uint256 valueSize, Point memory proto)
        private
        pure
        returns (Point memory pt)
    {
        pt = Point({feedId: bytes32(data[p:p + 32]), value: _uint(data, p + 32, valueSize), timestampMs: proto.timestampMs, signer: proto.signer});
    }

    /// @dev ecrecover of a 65-byte r‖s‖v signature; address(0) for an invalid or malleable one.
    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        if (sig.length != 65) revert InvalidRedstonePayload(P_SIGNATURE);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (v < 27) v += 27;
        // EIP-2: reject high-s signatures
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0 || (v != 27 && v != 28)) {
            return address(0);
        }
        return ecrecover(digest, v, r, s);
    }

    /// @dev Big-endian unsigned integer of `len` (≤ 32) bytes at `offset`.
    function _uint(bytes calldata data, uint256 offset, uint256 len) private pure returns (uint256 x) {
        if (offset + len > data.length) revert InvalidRedstonePayload(P_LENGTH);
        for (uint256 i; i < len; ++i) {
            x = (x << 8) | uint8(data[offset + i]);
        }
    }
}
