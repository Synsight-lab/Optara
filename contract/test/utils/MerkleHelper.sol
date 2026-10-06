// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Sorted-pair Merkle trees compatible with OpenZeppelin MerkleProof (ORACLES.md §3.2). An odd node at the
///         end of a level is promoted unchanged, so its proof has no element for that level.
library MerkleHelper {
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            level = _next(level);
        }
        return level[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory p) {
        bytes32[] memory tmp = new bytes32[](64);
        uint256 len;
        bytes32[] memory level = leaves;
        uint256 idx = index;
        while (level.length > 1) {
            uint256 sibling = idx ^ 1;
            if (sibling < level.length) tmp[len++] = level[sibling];
            level = _next(level);
            idx /= 2;
        }
        p = new bytes32[](len);
        for (uint256 i; i < len; ++i) {
            p[i] = tmp[i];
        }
    }

    function _next(bytes32[] memory level) private pure returns (bytes32[] memory next) {
        next = new bytes32[]((level.length + 1) / 2);
        for (uint256 i; i < next.length; ++i) {
            uint256 l = 2 * i;
            next[i] = l + 1 < level.length ? _hashPair(level[l], level[l + 1]) : level[l];
        }
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
