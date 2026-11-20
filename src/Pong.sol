// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/// @title Pong — hello-world callback contract for the Sentinel de-risk.
/// @notice Deployed on Base Sepolia. Receives callbacks requested by
/// PingReactive on Lasna through the Base Sepolia callback proxy
/// (0x476F44b11F5C942c58f4c8E3d0300E5710743585).
/// @dev The proxy overwrites the first 160 bits of the payload with the
/// address of the reactive contract that requested the callback, so the
/// first argument is always that address. Both guards are required:
/// onlyServiceProvider (caller is the proxy) + onlyCallbackSender (the
/// injected address is the authorized reactive contract).
/// Funding: callbacks are billed to this contract in Sepolia ETH — keep it
/// funded by a direct transfer to its balance; coverDebt() settles debt
/// from that balance.
contract Pong is AbstractCallback {
    event PongReceived(address indexed reactive, address indexed sender, uint256 count);

    uint256 public count;
    address public lastSender;
    address public lastReactive;

    constructor(IPayable callbackProxy_, address callbackSender_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {}

    /// @notice Settles outstanding debt to the callback proxy from this
    /// contract's own balance. Anyone can call it.
    function coverDebt() external {
        _coverDebt();
    }

    function pong(address reactive_, address sender_) external onlyServiceProvider onlyCallbackSender(reactive_) {
        count++;
        lastSender = sender_;
        lastReactive = reactive_;
        emit PongReceived(reactive_, sender_, count);
    }
}
