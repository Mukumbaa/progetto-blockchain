// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

// implementazione per contratto con delega
contract SimpleDelegate {
    function execute() external pure returns (string memory) {
        return "Delegated call successful!";
    }
}

contract EIP7702Test is Test {
    address payable public ALICE = payable(0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
    uint256 public ALICE_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    SimpleDelegate public implementation;

    function setUp() public {
        implementation = new SimpleDelegate();
    }

    function test_EIP7702_IsSupported() public {
        // Alice è un EOA senza codice
        assertEq(ALICE.code.length, 0, "ALICE should start with no code");

        // firma la delega
        Vm.SignedDelegation memory signedDelegation = vm.signDelegation(address(implementation), ALICE_PK);
        vm.attachDelegation(signedDelegation);

        // dopo la delega, Alice ha il codice
        assertTrue(ALICE.code.length > 0, "EIP-7702 not active: code not set on ALICE");
    }

    function test_DelegatedCall() public {
        // metto la delega
        Vm.SignedDelegation memory signedDelegation = vm.signDelegation(address(implementation), ALICE_PK);
        vm.attachDelegation(signedDelegation);

        // alice può eseguire il codice
        string memory result = SimpleDelegate(ALICE).execute();
        assertEq(result, "Delegated call successful!", "Delegated code execution failed");
    }
}
