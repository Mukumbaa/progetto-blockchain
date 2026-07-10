// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

library AssemblyUtils {
    function generateSessionHash(address sender, uint256 _timestamp) internal pure returns (bytes32 sessionHash) {
        assembly {
            // puntatore alla memoria libera (0x40)
            let ptr := mload(0x40)

            // metto i dati in memoria in sequenza (32 bytes ciascuno)
            mstore(ptr, sender)
            mstore(add(ptr, 0x20), _timestamp)

            // keccak256 sui 64 byte appena scritti
            sessionHash := keccak256(ptr, 0x40)
        }
    }

    function executeLowLevelCall(address target, uint256 value, bytes memory data) internal returns (bool success) {
        assembly {
            let dataPtr := add(data, 0x20)
            let dataLen := mload(data)

            // call(gas, address, value, argsOffset, argsSize, retOffset, retSize)
            success := call(gas(), target, value, dataPtr, dataLen, 0, 0)
        }
    }
}
