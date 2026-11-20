// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { DemoVault } from "../src/DemoVault.sol";
import { VerdictOracle } from "../src/VerdictOracle.sol";
import { SentinelReactive } from "../src/SentinelReactive.sol";
import { VaultGuard } from "../src/VaultGuard.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Mock of the Reactive system contract (same shape as Ping.t.sol's),
/// etched at the real SYSTEM address so subscribe()/react() execute.
contract MockSystem2 {
    struct CallbackReq {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    uint256 public subscribeCalls;
    uint256 public callbackCount;
    CallbackReq[] public callbackRequests;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscribeCalls++;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        callbackCount++;
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

/// @notice Unit tests for the Sentinel Phase 2 core. No fork needed.
contract SentinelUnitTest is Test {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address internal constant PROXY = address(0xBEEF);
    address internal constant FAKE_REACTIVE = address(0xCA11);
    address internal constant SAFE = address(0x5AFE);
    address internal constant USER = address(0xA11CE);
    uint256 internal constant VERDICT_TOPIC0 = uint256(keccak256("Verdict(uint256,address,uint256,uint8,string)"));

    DemoToken internal token;
    DemoVault internal vault;
    VerdictOracle internal oracle;
    SentinelReactive internal reactive;
    VaultGuard internal guard;
    MockSystem2 internal mockSystem;

    function setUp() public {
        mockSystem = new MockSystem2();
        vm.etch(SYSTEM, address(mockSystem).code);
        token = new DemoToken();
        vault = new DemoVault(token, 100_00000000); // $100, 8 decimals
        oracle = new VerdictOracle(address(this)); // this test is the writer
        reactive = new SentinelReactive(address(oracle), VERDICT_TOPIC0);
        guard = new VaultGuard(IPayable(payable(PROXY)), address(reactive));
        reactive.setDestination(address(guard));
        vault.setGuard(address(guard));
        vault.setSafeVault(SAFE);
        // Seed the vault: 1000 tUSD from the owner (this test contract).
        token.mint(address(this), 1000 ether);
        token.approve(address(vault), 1000 ether);
        vault.deposit(1000 ether);
    }

    // ---- DemoToken ----

    function testTokenMintOnlyOwner() public {
        vm.prank(USER);
        vm.expectRevert();
        token.mint(USER, 1 ether);
        token.mint(USER, 5 ether);
        assertEq(token.balanceOf(USER), 5 ether);
    }

    // ---- DemoVault ----

    function testDepositAndWithdrawAccounting() public {
        assertEq(token.balanceOf(address(vault)), 1000 ether);
        vault.withdraw(100 ether);
        assertEq(token.balanceOf(address(vault)), 900 ether);
        assertEq(token.balanceOf(address(this)), 100 ether);
    }

    function testLargeWithdrawalEmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit DemoVault.LargeWithdrawal(address(this), 300 ether, 3000);
        vault.withdraw(300 ether);
    }

    function testSmallWithdrawalEmitsNoLargeEvent() public {
        vm.recordLogs();
        vault.withdraw(100 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != DemoVault.LargeWithdrawal.selector);
        }
    }

    function testPriceDeviationEmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit DemoVault.PriceDeviation(100_00000000, 94_00000000, 600);
        vault.setPrice(94_00000000);
    }

    function testSmallPriceMoveEmitsNoDeviation() public {
        vm.recordLogs();
        vault.setPrice(99_00000000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != DemoVault.PriceDeviation.selector);
        }
    }

    function testFreezeBlocksWithdrawAndOnlyOwnerUnfreezes() public {
        vault.freeze();
        assertTrue(vault.frozen());
        vm.expectRevert(DemoVault.FrozenVault.selector);
        vault.withdraw(1 ether);
        vm.prank(USER);
        vm.expectRevert();
        vault.unfreeze();
        vault.unfreeze();
        assertFalse(vault.frozen());
    }

    function testRescueRequiresFrozenAndMovesFunds() public {
        // Direct rescue() from a non-guard reverts (guard check first).
        vm.expectRevert();
        vault.rescue();
        // As the guard itself, rescue() on an unfrozen vault reverts
        // NotFrozen (freeze-then-rescue order is enforced on-chain).
        vm.prank(address(guard));
        vm.expectRevert(DemoVault.NotFrozen.selector);
        vault.rescue();
        // The guard path freezes first, then rescues.
        vault.freeze();
        vm.prank(PROXY);
        guard.execute(address(reactive), address(vault), 2);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(SAFE), 1000 ether);
    }

    // ---- VerdictOracle ----

    function testOracleOnlyWriterCanWrite() public {
        vm.prank(USER);
        vm.expectRevert();
        oracle.writeVerdict(address(vault), 80, 1, "x");
        uint256 id = oracle.writeVerdict(address(vault), 80, 1, "large withdrawal 30%");
        assertEq(id, 0);
        assertEq(oracle.verdictCount(), 1);
        (address v, uint256 s, uint8 a, , ) = oracle.verdicts(0);
        assertEq(v, address(vault));
        assertEq(s, 80);
        assertEq(a, 1);
    }

    function testOracleRejectsInvalidScoreAndAction() public {
        vm.expectRevert();
        oracle.writeVerdict(address(vault), 101, 1, "x");
        vm.expectRevert();
        oracle.writeVerdict(address(vault), 50, 3, "x");
    }

    function testOracleWriterRotationOwnerOnly() public {
        vm.prank(USER);
        vm.expectRevert();
        oracle.setWriter(USER);
        oracle.setWriter(USER);
        assertEq(oracle.writer(), USER);
    }

    // ---- SentinelReactive ----

    function testReactRejectsNonSystemCaller() public {
        IReactive.LogRecord memory log = _verdictLog(0, 85, 1);
        vm.expectRevert();
        reactive.react(log);
    }

    function testReactIgnoresNonMatchingTopic() public {
        IReactive.LogRecord memory log = _verdictLog(0, 85, 1);
        log.topic0 = uint256(keccak256("Transfer(address,address,uint256)"));
        vm.prank(SYSTEM);
        reactive.react(log);
        assertEq(reactive.reactCount(), 0);
    }

    function testReactBelowThresholdRequestsNoCallback() public {
        IReactive.LogRecord memory log = _verdictLog(0, 42, 0);
        vm.prank(SYSTEM);
        reactive.react(log);
        assertEq(reactive.reactCount(), 1);
        assertEq(reactive.actedCount(), 0);
        MockSystem2 sys = MockSystem2(payable(SYSTEM));
        assertEq(sys.callbackCount(), 0);
    }

    function testReactHighRiskFreezeRequestsCallback() public {
        IReactive.LogRecord memory log = _verdictLog(3, 85, 1);
        vm.prank(SYSTEM);
        reactive.react(log);
        assertEq(reactive.reactCount(), 1);
        assertEq(reactive.actedCount(), 1);
        assertEq(reactive.lastRiskScore(), 85);
        assertEq(reactive.lastAction(), 1);
        assertEq(reactive.lastVault(), address(vault));
        MockSystem2 sys = MockSystem2(payable(SYSTEM));
        (uint256 cbChain, address cbRecipient, uint64 cbGas, bytes memory cbPayload) = sys.callbackRequests(0);
        assertEq(cbChain, 84532);
        assertEq(cbRecipient, address(guard));
        assertGe(cbGas, 100_000);
        assertEq(cbPayload, abi.encodeWithSignature("execute(address,address,uint8)", address(0), address(vault), 1));
    }

    function testReactHighScoreButActionNoneRequestsNoCallback() public {
        IReactive.LogRecord memory log = _verdictLog(1, 99, 0);
        vm.prank(SYSTEM);
        reactive.react(log);
        assertEq(reactive.reactCount(), 1);
        assertEq(reactive.actedCount(), 0);
    }

    function testReactRescueActionRequestsCallback() public {
        IReactive.LogRecord memory log = _verdictLog(2, 90, 2);
        vm.prank(SYSTEM);
        reactive.react(log);
        assertEq(reactive.actedCount(), 1);
        MockSystem2 sys = MockSystem2(payable(SYSTEM));
        (, , , bytes memory cbPayload) = sys.callbackRequests(0);
        assertEq(cbPayload, abi.encodeWithSignature("execute(address,address,uint8)", address(0), address(vault), 2));
    }

    // ---- VaultGuard ----

    function testGuardRejectsNonProxyCaller() public {
        vm.prank(USER);
        vm.expectRevert();
        guard.execute(address(reactive), address(vault), 1);
    }

    function testGuardRejectsWrongReactiveSender() public {
        vm.prank(PROXY);
        vm.expectRevert();
        guard.execute(FAKE_REACTIVE, address(vault), 1);
    }

    function testGuardFreezeCallbackFreezesVault() public {
        vm.prank(PROXY);
        guard.execute(address(reactive), address(vault), 1);
        assertTrue(vault.frozen());
    }

    function testGuardRescueCallbackFreezesAndRescues() public {
        vm.prank(PROXY);
        guard.execute(address(reactive), address(vault), 2);
        assertTrue(vault.frozen());
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(SAFE), 1000 ether);
    }

    function testGuardRejectsInvalidAction() public {
        vm.prank(PROXY);
        vm.expectRevert();
        guard.execute(address(reactive), address(vault), 9);
    }

    function _verdictLog(uint256 id, uint256 riskScore, uint8 action)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: 84532,
            contractAddress: address(oracle),
            topic0: VERDICT_TOPIC0,
            topic1: id,
            topic2: uint256(uint160(address(vault))),
            topic3: 0,
            data: abi.encode(riskScore, action, "test reasons"),
            blockNumber: block.number,
            opCode: 3,
            blockHash: uint256(blockhash(block.number - 1)),
            txHash: 0,
            logIndex: 0
        });
    }
}
