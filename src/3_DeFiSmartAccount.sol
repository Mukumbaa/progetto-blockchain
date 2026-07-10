// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./1_TransientStorage.sol";
import "./2_InlineAssembly.sol";

contract DeFiSmartAccount is TransientReentrancyGuard {
    bytes32 private constant SESSION_SLOT = keccak256("academic.session.active");

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    error SessionNotActive();
    error BatchExecutionFailed(uint256 index);

    function executeDeFiBatch(Call[] calldata calls) external payable nonReentrant {
        // hash univoco tramite la libreria Assembly
        bytes32 sessionHash = AssemblyUtils.generateSessionHash(msg.sender, block.timestamp);
        bytes32 slot = SESSION_SLOT;
        assembly {
            // storiamo l'hash nel Transient Storage
            // hash che serve a dire che siamo all'interno di un flusso autorizzato
            tstore(slot, sessionHash)
        }

        for (uint256 i = 0; i < calls.length; i++) {
            bool success = AssemblyUtils.executeLowLevelCall(calls[i].target, calls[i].value, calls[i].data);
            if (!success) revert BatchExecutionFailed(i);
        }

        assembly {
            // clean del transient storage
            tstore(slot, 0)
        }
    }

    function _verifySession() internal view {
        bytes32 slot = SESSION_SLOT;
        assembly {
            let activeSession := tload(slot)
            // iszero restituisce vero se activeSession è 0
            if iszero(activeSession) {
                // revertiamo usando il selettore di SessionNotActive()
                mstore(0x00, 0x1e360fbc)
                revert(0x1c, 0x04)
            }
        }
    }

    // si accettano fondi o callback nel momento in cui siano eseguite come parte del batch autorizzato
    receive() external payable {
        _verifySession();
    }

    fallback() external payable {
        _verifySession();
    }
}
