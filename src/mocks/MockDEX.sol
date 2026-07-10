// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;
import "./MockERC20.sol";

// un DEX fittizzio che scambia Token per ETH
contract MockDEX {
    MockERC20 public token;

    constructor(address _token) payable {
        token = MockERC20(_token);
    }

    // scambia 100 token per 1 ETH
    function swapTokensForEth(uint256 tokenAmount) external {
        // prende i token dall'utente
        token.transferFrom(msg.sender, address(this), tokenAmount);

        // vulnerabilità simulata: Invia ETH all'utente
        // se l'utente è un EOA normale, riceve l'ETH
        // se è uno Smart Account EIP-7702, si attiva la sua receive()
        (bool success,) = msg.sender.call{value: 1 ether}("");
        require(success, "DEX: ETH transfer failed");
    }
}
