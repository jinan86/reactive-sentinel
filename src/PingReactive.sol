// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title PingReactive — hello-world reactive contract for the Sentinel de-risk.
/// @notice Deployed on Lasna (chain 5318007). Subscribes to Ping events emitted
/// by PingEmitter on Base Sepolia (chain 84532). On each matching event it
/// requests a callback to the Pong contract on Base Sepolia.
/// @dev Follows the deployment order from the Reactive docs: deploy this
/// contract first, then the callback contract (which needs this address),
/// then call setDestination() with the callback address (owner-only).
/// Funding: keep lREACT in this contract's own balance (plain transfer);
/// the system contract settles debt from it via pay() / coverDebt().
contract PingReactive is AbstractReactive {
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;

    /// @notice Callback gas limit. Minimum enforced by the network is 100,000.
    /// The Base Sepolia proxy withholds _extraGas (80,000) + _maxChargeGas
    /// (50,000) before forwarding, so 300,000 leaves ample room for Pong.
    uint64 public constant CALLBACK_GAS_LIMIT = 300_000;

    address public immutable origin;
    uint256 public immutable pingTopic0;
    address public owner;
    address public destination;

    uint256 public reactCount;
    uint256 public lastValue;
    address public lastSender;

    event Reacted(uint256 indexed value, address indexed sender, uint256 nonce);
    event CallbackRequested(address indexed destination, uint256 value);
    event DestinationSet(address indexed destination);

    error NotOwner(address caller);

    constructor(address origin_, uint256 pingTopic0_) {
        owner = msg.sender;
        origin = origin_;
        pingTopic0 = pingTopic0_;
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID, origin_, pingTopic0_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @notice Set (or change) the callback recipient. Owner-only.
    function setDestination(address destination_) external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        destination = destination_;
        emit DestinationSet(destination_);
    }

    /// @notice Settles outstanding debt to the system contract from this
    /// contract's own balance. Anyone can call it.
    function coverDebt() external {
        _coverDebt();
    }

    /// @inheritdoc IReactive
    /// @dev Ping(address indexed sender, uint256 value, uint256 indexed nonce)
    /// arrives as LOG3: topic0 = signature, topic1 = sender, topic2 = nonce,
    /// data = abi.encode(value). Non-matching logs fall through silently
    /// (never revert: a reverting react() is still billed).
    function react(LogRecord memory log_) external override onlySystem {
        if (log_.topic0 != pingTopic0 || log_.opCode != 3) return;
        uint256 value = abi.decode(log_.data, (uint256));
        address sender = address(uint160(log_.topic1));
        uint256 nonce = log_.topic2;

        reactCount++;
        lastValue = value;
        lastSender = sender;
        emit Reacted(value, sender, nonce);

        if (destination == address(0)) return;
        bytes memory payload = abi.encodeWithSignature("pong(address,address)", address(0), sender);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: BASE_SEPOLIA_CHAIN_ID,
                recipient: destination,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
        emit CallbackRequested(destination, value);
    }
}
