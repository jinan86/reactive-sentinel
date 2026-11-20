// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { DemoVault } from "../src/DemoVault.sol";
import { VerdictOracle } from "../src/VerdictOracle.sol";

/// @notice Phase 2 step A (Base Sepolia): deploy the demo vault stack.
/// Deploys DemoToken, DemoVault (mock price $100), VerdictOracle (writer =
/// deployer = the AI service key), then seeds the vault with 1000 tUSD
/// from the deployer and sets the safe vault to the deployer (demo).
/// Writes deployments/phase2-base.json.
contract DeployPhase2Base is Script {
    function run() external {
        vm.startBroadcast();
        DemoToken token = new DemoToken();
        DemoVault vault = new DemoVault(token, 100_00000000);
        VerdictOracle oracle = new VerdictOracle(msg.sender);
        token.mint(msg.sender, 1000 ether);
        token.approve(address(vault), 1000 ether);
        vault.deposit(1000 ether);
        vault.setSafeVault(msg.sender);
        vm.stopBroadcast();

        console.log("DemoToken:", address(token));
        console.log("DemoVault:", address(vault));
        console.log("VerdictOracle:", address(oracle));
        string memory json = string.concat(
            '{"chain":"base_sepolia","chainId":84532,"token":"',
            vm.toString(address(token)),
            '","vault":"',
            vm.toString(address(vault)),
            '","oracle":"',
            vm.toString(address(oracle)),
            '"}'
        );
        vm.writeJson(json, "deployments/phase2-base.json");
        console.log("Wrote deployments/phase2-base.json");
    }
}
