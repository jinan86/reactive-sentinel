// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { PingEmitter } from "../src/PingEmitter.sol";
import { PingReactive } from "../src/PingReactive.sol";
import { Pong } from "../src/Pong.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";

/// @notice Fork test: proves the hello-world contracts work against the REAL
/// deployed system contract (Lasna) and callback proxy (Base Sepolia).
/// A real Ping event is emitted on the Base Sepolia fork, its log is read
/// back, and the resulting LogRecord is fed to react() on the Lasna fork
/// with the system contract as caller — exactly what Reactive nodes do live.
/// Deployment order follows the docs (reactive first, callback second, then
/// setDestination), but the emitter is deployed first here only to learn its
/// address — no address prediction is used anywhere.
/// What this does NOT prove (needs funded live deployment): the Reactive
/// nodes picking up the event and the proxy delivering the callback.
contract PingForkTest is Test {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address internal constant BASE_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant PING_TOPIC0 = uint256(keccak256("Ping(address,uint256,uint256)"));

    uint256 internal lasnaFork;
    uint256 internal baseFork;

    function setUp() public {
        lasnaFork = vm.createFork("lasna");
        baseFork = vm.createFork("base_sepolia");
    }

    function testForkLoopPingToReact() public {
        // 1. Base Sepolia fork: deploy the emitter (learn its real address).
        vm.selectFork(baseFork);
        PingEmitter emitter = new PingEmitter();
        address emitterAddr = address(emitter);

        // 2. Lasna fork: deploy the reactive contract. Its constructor
        // subscribes on the REAL system contract — if the interface did not
        // match the deployed system, this would revert.
        vm.selectFork(lasnaFork);
        PingReactive reactive = new PingReactive(emitterAddr, PING_TOPIC0);
        assertEq(address(reactive._SERVICE_PROVIDER()), SYSTEM);

        // 3. Base Sepolia fork: deploy the callback contract.
        vm.selectFork(baseFork);
        Pong pong = new Pong(IPayable(payable(BASE_PROXY)), address(reactive));
        assertEq(address(pong._SERVICE_PROVIDER()), BASE_PROXY);
        assertEq(pong._CALLBACK_SENDER(), address(reactive));

        // 4. Lasna fork: wire the destination (owner-only setter).
        vm.selectFork(lasnaFork);
        reactive.setDestination(address(pong));
        assertEq(reactive.destination(), address(pong));

        // 5. Base Sepolia fork: emit a real ping and capture its log.
        vm.selectFork(baseFork);
        vm.recordLogs();
        emitter.ping(777);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], bytes32(PING_TOPIC0));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].emitter, emitterAddr);

        // 6. Lasna fork: feed the real log to react() as SYSTEM.
        IReactive.LogRecord memory logRecord = IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: emitterAddr,
            topic0: uint256(logs[0].topics[0]),
            topic1: uint256(logs[0].topics[1]),
            topic2: uint256(logs[0].topics[2]),
            topic3: 0,
            data: logs[0].data,
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });

        vm.selectFork(lasnaFork);
        vm.prank(SYSTEM);
        vm.expectEmit(true, true, false, true, address(reactive));
        emit PingReactive.Reacted(777, address(this), 1);
        reactive.react(logRecord);

        assertEq(reactive.reactCount(), 1);
        assertEq(reactive.lastValue(), 777);
        assertEq(reactive.lastSender(), address(this));
    }
}
