// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

abstract contract TransientReentrancyGuard {
    // slot di memoria calcolato in modo deterministico
    bytes32 private constant REENTRANCY_SLOT = keccak256("academic.reentrancy.guard");

    error ReentrancyDetected();

    modifier nonReentrant() {
        bytes32 slot = REENTRANCY_SLOT;
        assembly {
            if tload(slot) {
                // carica il selettore di ReentrancyDetected() in memoria
                mstore(0x00, 0x5a1532f3)
                revert(0x1c, 0x04)
            }
            // TSTORE imposta il lock
            tstore(slot, 1)
        }
        _;
        assembly {
            // sblocca il lock
            tstore(slot, 0)
        }
    }
}
