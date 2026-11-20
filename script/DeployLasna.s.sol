// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { PingReactive } from "../src/PingReactive.sol";

/// @notice Step 2 of the hello-world deployment (Lasna).
/// Deploys PingReactive subscribed to the PingEmitter (env EMITTER_ADDRESS)
/// and funds its own balance in lREACT (env LREACT_DEPOSIT, default
/// 0.5 lREACT) so react() txs and callback requests can be settled from it.
/// Requires the deployer to hold lREACT first (see FUNDING.md).
contract DeployLasna is Script {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;

    function run() external {
        address emitter = vm.envAddress("EMITTER_ADDRESS");
        uint256 deposit = vm.envOr("LREACT_DEPOSIT", uint256(0.5 ether));
        uint256 topic0 = uint256(keccak256("Ping(address,uint256,uint256)"));

        vm.startBroadcast();
        PingReactive reactive = new PingReactive(emitter, topic0);
        // Fund the reactive contract's own balance in lREACT: the system
        // contract settles this contract's debt from its balance via pay()
        // (called by the system) or coverDebt(). A plain transfer is the
        // funding path in the Omni library v0.1.0 (no depositTo in the lib).
        (bool funded, ) = payable(address(reactive)).call{ value: deposit }("");
        require(funded, "fund reactive failed");
        vm.stopBroadcast();

        console.log("PingReactive:", address(reactive));
        console.log("Deposited lREACT to reactive:", deposit);
        string memory json = string.concat(
            '{"chain":"lasna","chainId":5318007,"reactive":"',
            vm.toString(address(reactive)),
            '","emitter":"',
            vm.toString(emitter),
            '"}'
        );
        vm.writeJson(json, "deployments/lasna.json");
        console.log("Wrote deployments/lasna.json");
    }
}
