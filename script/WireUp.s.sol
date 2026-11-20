// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { PingReactive } from "../src/PingReactive.sol";

/// @notice Step 4 of the hello-world deployment (Lasna).
/// Wires the Pong address into PingReactive (owner-only setDestination).
/// Env: REACTIVE_ADDRESS, PONG_ADDRESS.
contract WireUp is Script {
    function run() external {
        address reactive = vm.envAddress("REACTIVE_ADDRESS");
        address pong = vm.envAddress("PONG_ADDRESS");

        vm.startBroadcast();
        PingReactive(payable(reactive)).setDestination(pong);
        vm.stopBroadcast();

        console.log("Destination set:", pong, "on reactive:", reactive);
    }
}
