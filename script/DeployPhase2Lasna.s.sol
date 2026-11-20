// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { SentinelReactive } from "../src/SentinelReactive.sol";

/// @notice Phase 2 step B (Lasna): deploy SentinelReactive subscribed to
/// the VerdictOracle (env ORACLE_ADDRESS) and fund its own balance in
/// lREACT (env LREACT_DEPOSIT, default 0.5 lREACT) so react() txs and
/// callback requests can be settled from it. Writes
/// deployments/phase2-lasna.json.
contract DeployPhase2Lasna is Script {
    function run() external {
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        uint256 deposit = vm.envOr("LREACT_DEPOSIT", uint256(0.5 ether));
        uint256 topic0 = uint256(keccak256("Verdict(uint256,address,uint256,uint8,string)"));

        vm.startBroadcast();
        SentinelReactive reactive = new SentinelReactive(oracle, topic0);
        (bool funded, ) = payable(address(reactive)).call{ value: deposit }("");
        require(funded, "fund reactive failed");
        vm.stopBroadcast();

        console.log("SentinelReactive:", address(reactive));
        console.log("Deposited lREACT to reactive:", deposit);
        string memory json = string.concat(
            '{"chain":"lasna","chainId":5318007,"reactive":"',
            vm.toString(address(reactive)),
            '","oracle":"',
            vm.toString(oracle),
            '"}'
        );
        vm.writeJson(json, "deployments/phase2-lasna.json");
        console.log("Wrote deployments/phase2-lasna.json");
    }
}
