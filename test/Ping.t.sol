// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { PingEmitter } from "../src/PingEmitter.sol";
import { PingReactive } from "../src/PingReactive.sol";
import { Pong } from "../src/Pong.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Minimal mock of the Reactive system contract, etched at the real
/// SYSTEM address so constructor subscribe() and react()'s callback request
/// execute instead of reverting on the "call to non-contract" check.
contract MockSystem {
    struct CallbackReq {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    uint256 public subscribeCalls;
    CallbackReq[] public callbackRequests;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscribeCalls++;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        callbackRequests.push(CallbackReq(c.chainId, c.recipient, c.gasLimit, c.payload));
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function reserves(address) external pure returns (uint256) {
        return 0;
    }

    function depositTo(address) external payable {}

    receive() external payable {}
}

/// @notice Unit tests for the hello-world loop. No fork needed: the system
/// contract address (0x8888...) has no code locally, so subscribe/callback
/// calls succeed silently and react() is driven with vm.prank(SYSTEM).
contract PingUnitTest is Test {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address internal constant PROXY = address(0xBEEF);
    address internal constant FAKE_REACTIVE = address(0xCA11);
    uint256 internal constant PING_TOPIC0 = uint256(keccak256("Ping(address,uint256,uint256)"));

    PingEmitter internal emitter;
    PingReactive internal reactive;
    Pong internal pong;
    MockSystem internal mockSystem;

    function setUp() public {
        mockSystem = new MockSystem();
        vm.etch(SYSTEM, address(mockSystem).code);
        emitter = new PingEmitter();
        reactive = new PingReactive(address(emitter), PING_TOPIC0);
        // Pong needs the reactive address; deploy with the real one.
        pong = new Pong(IPayable(payable(PROXY)), address(reactive));
        reactive.setDestination(address(pong));
    }

    function testPingEmitsEventAndIncrementsNonce() public {
        vm.expectEmit(true, true, true, true, address(emitter));
        emit PingEmitter.Ping(address(this), 42, 1);
        emitter.ping(42);
        assertEq(emitter.nonce(), 1);
        emitter.ping(7);
        assertEq(emitter.nonce(), 2);
    }

    function testReactRejectsNonSystemCaller() public {
        IReactive.LogRecord memory log = _pingLog(address(this), 42, 1);
        vm.expectRevert();
        reactive.react(log);
    }

    function testReactIgnoresNonMatchingTopic() public {
        IReactive.LogRecord memory log = _pingLog(address(this), 42, 1);
        log.topic0 = uint256(keccak256("Transfer(address,address,uint256)"));
        vm.prank(SYSTEM);
        reactive.react(log);
        assertEq(reactive.reactCount(), 0);
    }

    function testReactIgnoresWrongOpCode() public {
        IReactive.LogRecord memory log = _pingLog(address(this), 42, 1);
        log.opCode = 2; // LOG2 instead of LOG3
        vm.prank(SYSTEM);
        reactive.react(log);
        assertEq(reactive.reactCount(), 0);
    }

    function testReactProcessesPingAndRequestsCallback() public {
        IReactive.LogRecord memory log = _pingLog(address(0xABCD), 1234, 5);
        vm.prank(SYSTEM);
        vm.expectEmit(true, true, false, true, address(reactive));
        emit PingReactive.Reacted(1234, address(0xABCD), 5);
        reactive.react(log);
        assertEq(reactive.reactCount(), 1);
        assertEq(reactive.lastValue(), 1234);
        assertEq(reactive.lastSender(), address(0xABCD));
        // The callback request reached the system contract. State lives at
        // SYSTEM (the etched copy), not at the mock's own address.
        MockSystem sys = MockSystem(payable(SYSTEM));
        assertEq(sys.subscribeCalls(), 1);
        (uint256 cbChain, address cbRecipient, uint64 cbGas, bytes memory cbPayload) =
            sys.callbackRequests(0);
        assertEq(cbChain, 84532);
        assertEq(cbRecipient, address(pong));
        assertGe(cbGas, 100_000);
        assertEq(cbPayload, abi.encodeWithSignature("pong(address,address)", address(0), address(0xABCD)));
    }

    function testReactWithoutDestinationStillCounts() public {
        PingReactive noDest = new PingReactive(address(emitter), PING_TOPIC0);
        IReactive.LogRecord memory log = _pingLog(address(this), 9, 1);
        vm.prank(SYSTEM);
        noDest.react(log);
        assertEq(noDest.reactCount(), 1);
    }

    function testSetDestinationOnlyOwner() public {
        vm.prank(address(0x1234));
        vm.expectRevert();
        reactive.setDestination(address(0x5678));
        reactive.setDestination(address(0x5678));
        assertEq(reactive.destination(), address(0x5678));
    }

    function testPongRejectsNonProxyCaller() public {
        vm.prank(address(0x1234));
        vm.expectRevert();
        pong.pong(address(reactive), address(this));
    }

    function testPongRejectsWrongReactiveSender() public {
        vm.prank(PROXY);
        vm.expectRevert();
        pong.pong(FAKE_REACTIVE, address(this));
    }

    function testPongAcceptsLegitCallback() public {
        vm.prank(PROXY);
        vm.expectEmit(true, true, false, true, address(pong));
        emit Pong.PongReceived(address(reactive), address(0xABCD), 1);
        pong.pong(address(reactive), address(0xABCD));
        assertEq(pong.count(), 1);
        assertEq(pong.lastSender(), address(0xABCD));
        assertEq(pong.lastReactive(), address(reactive));
    }

    function _pingLog(address sender, uint256 value, uint256 nonce)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: 84532,
            contractAddress: address(emitter),
            topic0: PING_TOPIC0,
            topic1: uint256(uint160(sender)),
            topic2: nonce,
            topic3: 0,
            data: abi.encode(value),
            blockNumber: block.number,
            opCode: 3,
            blockHash: uint256(blockhash(block.number - 1)),
            txHash: 0,
            logIndex: 0
        });
    }
}
