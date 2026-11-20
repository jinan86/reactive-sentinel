// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { VaultGuard } from "../src/VaultGuard.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

/// @notice Phase 2 step C (Base Sepolia): deploy VaultGuard, authenticated
/// to the SentinelReactive contract (env REACTIVE_ADDRESS). Funded with
/// Sepolia ETH (env GUARD_FUND, default 0.001 ETH) so callback billing can
/// be settled via coverDebt(). Writes deployments/phase2-guard.json.
contract DeployPhase2Guard is Script {
    address internal constant BASE_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    function run() external {
        address reactive = vm.envAddress("REACTIVE_ADDRESS");
        uint256 guardFund = vm.envOr("GUARD_FUND", uint256(0.001 ether));

        vm.startBroadcast();
        VaultGuard guard = new VaultGuard{ value: guardFund }(IPayable(payable(BASE_PROXY)), reactive);
        vm.stopBroadcast();

        console.log("VaultGuard:", address(guard));
        string memory json = string.concat(
            '{"chain":"base_sepolia","chainId":84532,"guard":"',
            vm.toString(address(guard)),
            '","reactive":"',
            vm.toString(reactive),
            '"}'
        );
        vm.writeJson(json, "deployments/phase2-guard.json");
        console.log("Wrote deployments/phase2-guard.json");
    }
}
