// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { Pong } from "../src/Pong.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

/// @notice Step 3 of the hello-world deployment (Base Sepolia).
/// Deploys the Pong callback contract funded with Sepolia ETH
/// (env PONG_FUND, default 0.01 ETH) so callback billing can be settled
/// via coverDebt(). The reactive contract address comes from env
/// REACTIVE_ADDRESS (deployments/lasna.json).
contract DeployPong is Script {
    address internal constant BASE_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    function run() external {
        address reactive = vm.envAddress("REACTIVE_ADDRESS");
        uint256 pongFund = vm.envOr("PONG_FUND", uint256(0.01 ether));

        vm.startBroadcast();
        Pong pong = new Pong{ value: pongFund }(IPayable(payable(BASE_PROXY)), reactive);
        vm.stopBroadcast();

        console.log("Pong:", address(pong));
        string memory json = string.concat(
            '{"chain":"base_sepolia","chainId":84532,"pong":"',
            vm.toString(address(pong)),
            '","reactive":"',
            vm.toString(reactive),
            '"}'
        );
        vm.writeJson(json, "deployments/pong.json");
        console.log("Wrote deployments/pong.json");
    }
}
