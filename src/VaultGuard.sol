// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { DemoVault } from "./DemoVault.sol";

/// @title VaultGuard — authenticated callback that enforces Sentinel verdicts.
/// @notice Deployed on Base Sepolia. Receives callbacks requested by
/// SentinelReactive on Lasna through the Base Sepolia callback proxy
/// (0x476F44b11F5C942c58f4c8E3d0300E5710743585). The proxy overwrites the
/// first 160 bits of the payload with the reactive contract's address, so
/// execute() sees (reactive, vault, action) and both guards apply:
/// onlyServiceProvider (caller is the proxy) + onlyCallbackSender (the
/// injected address is the authorized reactive contract).
/// Actions: 1 = FREEZE (vault.freeze), 2 = RESCUE (vault.freeze if needed,
/// then vault.rescue — funds move to the vault's safeVault).
/// Funding: callbacks are billed to this contract in Sepolia ETH — keep it
/// funded by a direct transfer to its balance; coverDebt() settles debt
/// from that balance.
contract VaultGuard is AbstractCallback {
    event GuardExecuted(address indexed reactive, address indexed vault, uint8 action);

    error InvalidAction(uint8 action);

    constructor(IPayable callbackProxy_, address callbackSender_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {}

    /// @notice Settles outstanding debt to the callback proxy from this
    /// contract's own balance. Anyone can call it.
    function coverDebt() external {
        _coverDebt();
    }

    function execute(address reactive_, address vault_, uint8 action_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        if (action_ == 1) {
            DemoVault(vault_).freeze();
        } else if (action_ == 2) {
            DemoVault vault = DemoVault(vault_);
            if (!vault.frozen()) vault.freeze();
            vault.rescue();
        } else {
            revert InvalidAction(action_);
        }
        emit GuardExecuted(reactive_, vault_, action_);
    }
}
