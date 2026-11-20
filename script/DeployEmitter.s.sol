// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { PingEmitter } from "../src/PingEmitter.sol";

/// @notice Step 1 of the hello-world deployment (Base Sepolia).
/// Deploys the PingEmitter origin contract and records its address in
/// deployments/emitter.json for the Lasna step.
contract DeployEmitter is Script {
    function run() external {
        vm.startBroadcast();
        PingEmitter emitter = new PingEmitter();
        vm.stopBroadcast();

        console.log("PingEmitter:", address(emitter));
        string memory json = string.concat(
            '{"chain":"base_sepolia","chainId":84532,"emitter":"', vm.toString(address(emitter)), '"}'
        );
        vm.writeJson(json, "deployments/emitter.json");
        console.log("Wrote deployments/emitter.json");
    }
}
