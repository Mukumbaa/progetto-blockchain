// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DeFiSmartAccount} from "../src/3_DeFiSmartAccount.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockDEX} from "../src/mocks/MockDEX.sol";


// token malevolo per test di reentrancy 
contract MaliciousToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    DeFiSmartAccount public target;
    bool public attackEnabled;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        if (attackEnabled && recipient == address(target)) {
            // attacco reentrancy
            DeFiSmartAccount.Call[] memory empty;
            target.executeDeFiBatch(empty);
        }
        require(balanceOf[sender] >= amount, "balance too low");
        require(allowance[sender][msg.sender] >= amount, "allowance too low");
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;
        allowance[sender][msg.sender] -= amount;
        return true;
    }

    function setAttack(address _target, bool _enable) external {
        target = DeFiSmartAccount(payable(_target));
        attackEnabled = _enable;
    }
}

// DEX fatto apposta per fallire
contract FailingDEX {
    MockERC20 public token;
    bool public fail;

    constructor(address _token) {
        token = MockERC20(_token);
    }

    function setFail(bool _fail) external {
        fail = _fail;
    }

    function swapTokensForEth(uint256 amountIn) external {
        if (fail) revert("DEX failed intentionally");
        require(token.transferFrom(msg.sender, address(this), amountIn), "transfer failed");
        payable(msg.sender).transfer(1 ether);
    }

    receive() external payable {}
}

// contratto ricevitore per test di invio ETH
contract EthReceiver {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

contract DeFiSmartAccountTest is Test {
    DeFiSmartAccount public implementation;
    MockERC20 public token;
    MockDEX public dex;

    // creiamo una chiave privata reale e deriviamo l'EOA di Alice
    uint256 public alicePrivateKey = 0xA11CE;
    address public aliceEOA;

    function setUp() public {
        implementation = new DeFiSmartAccount();
        token = new MockERC20();
        dex = new MockDEX{value: 10 ether}(address(token));

        // address di Alice a partire dalla chiave privata
        aliceEOA = vm.addr(alicePrivateKey);

        vm.deal(aliceEOA, 1 ether);
        token.mint(aliceEOA, 1000);
    }


    function test_EIP7702_DeFiBatching() public {
        bytes memory approveData = abi.encodeWithSelector(MockERC20.approve.selector, address(dex), 100);
        bytes memory swapData = abi.encodeWithSelector(MockDEX.swapTokensForEth.selector, 100);

        DeFiSmartAccount.Call[] memory batch = new DeFiSmartAccount.Call[](2);
        batch[0] = DeFiSmartAccount.Call({target: address(token), value: 0, data: approveData});
        batch[1] = DeFiSmartAccount.Call({target: address(dex), value: 0, data: swapData});

        // EIP-7702 Alice firma la delega a DeFiSmartAccount
        // foundry la include nella transazione successiva
        vm.signAndAttachDelegation(address(implementation), alicePrivateKey);

        vm.prank(aliceEOA);
        DeFiSmartAccount(payable(aliceEOA)).executeDeFiBatch(batch);

        assertEq(token.balanceOf(aliceEOA), 900);
        assertEq(aliceEOA.balance, 2 ether);
    }

    function test_RevertWhen_FallbackCalledOutsideSession() public {
        // unaltro invia una transazione allegando l'autorizzazione firmata da Alice
        // questo aggiorna il codice di Alice a DeFiSmartAccount durante l'esecuzione
        vm.signAndAttachDelegation(address(implementation), alicePrivateKey);

        vm.prank(address(0xBAD));
        vm.expectRevert(DeFiSmartAccount.SessionNotActive.selector);
        (bool success,) = aliceEOA.call{value: 0.1 ether}("");
        success;
    }

    function test_GasReport_DirectCall() public {
        DeFiSmartAccount.Call[] memory batch = new DeFiSmartAccount.Call[](0);

        vm.signAndAttachDelegation(address(implementation), alicePrivateKey);

        vm.prank(aliceEOA);
        DeFiSmartAccount(payable(aliceEOA)).executeDeFiBatch(batch);
    }


    function test_RevertWhen_ReentrancyAttempted() public {
        MaliciousToken malToken = new MaliciousToken("Mal", "MAL", 18);
        malToken.mint(aliceEOA, 1000);
        MockDEX malDex = new MockDEX(address(malToken));
        malToken.setAttack(address(aliceEOA), true);

        DeFiSmartAccount.Call[] memory batch = new DeFiSmartAccount.Call[](2);
        batch[0] = DeFiSmartAccount.Call({
            target: address(malToken),
            value: 0,
            data: abi.encodeWithSelector(MaliciousToken.approve.selector, address(malDex), 100)
        });
        batch[1] = DeFiSmartAccount.Call({
            target: address(malDex), value: 0, data: abi.encodeWithSelector(MockDEX.swapTokensForEth.selector, 100)
        });

        vm.signAndAttachDelegation(address(implementation), alicePrivateKey);

        vm.prank(aliceEOA);
        vm.expectRevert(abi.encodeWithSelector(DeFiSmartAccount.BatchExecutionFailed.selector, 1));
        DeFiSmartAccount(payable(aliceEOA)).executeDeFiBatch(batch);
    }

    function test_EIP7702_BatchWithEthTransfer() public {
        vm.deal(aliceEOA, 2 ether);

        EthReceiver receiver = new EthReceiver();

        DeFiSmartAccount.Call[] memory batch = new DeFiSmartAccount.Call[](3);
        batch[0] = DeFiSmartAccount.Call({
            target: address(token),
            value: 0,
            data: abi.encodeWithSelector(MockERC20.approve.selector, address(dex), 100)
        });
        batch[1] = DeFiSmartAccount.Call({
            target: address(dex), value: 0, data: abi.encodeWithSelector(MockDEX.swapTokensForEth.selector, 100)
        });
        batch[2] = DeFiSmartAccount.Call({target: address(receiver), value: 0.5 ether, data: ""});

        vm.signAndAttachDelegation(address(implementation), alicePrivateKey);

        vm.prank(aliceEOA);
        DeFiSmartAccount(payable(aliceEOA)).executeDeFiBatch(batch);

        assertEq(aliceEOA.balance, 2.5 ether);
        assertEq(address(receiver).balance, 0.5 ether);
        assertEq(token.balanceOf(aliceEOA), 900);
    }

    function test_RevertWhen_BatchPartialFailure() public {
        vm.deal(aliceEOA, 1 ether);

        FailingDEX failDex = new FailingDEX(address(token));
        token.approve(address(failDex), 100);

        DeFiSmartAccount.Call[] memory batch = new DeFiSmartAccount.Call[](2);
        batch[0] = DeFiSmartAccount.Call({
            target: address(token),
            value: 0,
            data: abi.encodeWithSelector(MockERC20.approve.selector, address(failDex), 100)
        });
        batch[1] = DeFiSmartAccount.Call({
            target: address(failDex), value: 0, data: abi.encodeWithSelector(FailingDEX.swapTokensForEth.selector, 100)
        });

        failDex.setFail(true);

        vm.signAndAttachDelegation(address(implementation), alicePrivateKey);

        vm.prank(aliceEOA);
        vm.expectRevert(abi.encodeWithSelector(DeFiSmartAccount.BatchExecutionFailed.selector, 1));
        DeFiSmartAccount(payable(aliceEOA)).executeDeFiBatch(batch);

        assertEq(token.balanceOf(aliceEOA), 1000);
        assertEq(aliceEOA.balance, 1 ether);
    }

    function test_GasComparison_BatchedVsSeparate() public {
        uint256 gasSeparate;
        {
            vm.prank(aliceEOA);
            token.approve(address(dex), 100);
            uint256 gasBefore = gasleft();
            vm.prank(aliceEOA);
            dex.swapTokensForEth(100);
            uint256 gasAfter = gasleft();
            gasSeparate = gasBefore - gasAfter;
        }

        // reset per il batch
        vm.deal(aliceEOA, 1 ether);
        token.mint(aliceEOA, 1000);

        uint256 gasBatch;
        {
            DeFiSmartAccount.Call[] memory batch = new DeFiSmartAccount.Call[](2);
            batch[0] = DeFiSmartAccount.Call({
                target: address(token),
                value: 0,
                data: abi.encodeWithSelector(MockERC20.approve.selector, address(dex), 100)
            });
            batch[1] = DeFiSmartAccount.Call({
                target: address(dex), value: 0, data: abi.encodeWithSelector(MockDEX.swapTokensForEth.selector, 100)
            });

            // link della delega nativa
            vm.signAndAttachDelegation(address(implementation), alicePrivateKey);

            vm.prank(aliceEOA);
            uint256 gasBefore = gasleft();
            DeFiSmartAccount(payable(aliceEOA)).executeDeFiBatch(batch);
            uint256 gasAfter = gasleft();
            gasBatch = gasBefore - gasAfter;
        }

        assertLt(gasBatch, gasSeparate, "Il batch consuma meno gas");
        console.log("Gas separate:", gasSeparate);
        console.log("Gas batch:", gasBatch);
        console.log("Risparmio:", gasSeparate - gasBatch);
    }

    function test_EIP7702_RevokeDelegation() public {
        // Alice firma ed esegue un batch per verificare che la delega funzioni
        DeFiSmartAccount.Call[] memory batch = new DeFiSmartAccount.Call[](1);
        batch[0] = DeFiSmartAccount.Call({
            target: address(token),
            value: 0,
            data: abi.encodeWithSelector(MockERC20.approve.selector, address(dex), 100)
        });

        vm.signAndAttachDelegation(address(implementation), alicePrivateKey);

        vm.prank(aliceEOA);
        DeFiSmartAccount(payable(aliceEOA)).executeDeFiBatch(batch);
        assertEq(token.allowance(aliceEOA, address(dex)), 100);

        // EIP-7702 revoca si firma una delega diretta all'indirizzo nullo (address(0))
        // questo azzera il puntatore di delega dell'EOA
        vm.signAndAttachDelegation(address(0), alicePrivateKey);

        // transazione fittizia per applicare la delega di revoca (azzera il codice)
        vm.prank(aliceEOA);
        (bool ok,) = aliceEOA.call("");
        assertTrue(ok);

        // tentare un batch ora fallirà o non farà nulla poiché Alice non ha più codice associato
        address otherSpender = address(0x1234);
        DeFiSmartAccount.Call[] memory batch2 = new DeFiSmartAccount.Call[](1);
        batch2[0] = DeFiSmartAccount.Call({
            target: address(token), value: 0, data: abi.encodeWithSelector(MockERC20.approve.selector, otherSpender, 50)
        });

        vm.prank(aliceEOA);
        // Alice è di nuovo un EOA, executeDeFiBatch non trova codice
        // chiamata a EOA senza codice, successo, nessuna esecuzione
        (bool success,) = aliceEOA.call(abi.encodeWithSelector(DeFiSmartAccount.executeDeFiBatch.selector, batch2));
        assertTrue(success, "La chiamata ha successo ma non esegue codice");

        // verifica che l'approvazione non sia avvenuta vedendo se il token non è mutato
        assertEq(token.allowance(aliceEOA, otherSpender), 0);
        assertEq(token.allowance(aliceEOA, address(dex)), 100);

        // Alice può inviare una transazione nativa come normale EOA
        address bob = address(0x5678);
        uint256 aliceBalance = aliceEOA.balance;
        vm.prank(aliceEOA);
        (bool sent,) = bob.call{value: 0.1 ether}("");
        assertTrue(sent);
        assertEq(aliceEOA.balance, aliceBalance - 0.1 ether);
    }
}
