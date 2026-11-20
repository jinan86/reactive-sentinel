// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title SentinelReactive — the enforcement half of Sentinel.
/// @notice Deployed on Lasna (chain 5318007). Subscribes to Verdict events
/// emitted by VerdictOracle on Base Sepolia (chain 84532). On each verdict
/// it records the decision; if riskScore >= RISK_THRESHOLD and the action
/// is FREEZE or RESCUE, it requests a callback to VaultGuard, which
/// freezes/rescues the vault. Below-threshold verdicts cost a react() fee
/// but trigger no callback — fail closed, by design.
/// @dev Verdict(uint256 indexed id, address indexed vault, uint256
/// riskScore, uint8 action, string reasons) arrives as LOG3: topic0 =
/// signature, topic1 = id, topic2 = vault, data = (riskScore, action,
/// reasons). The callback payload is execute(address,address,uint8):
/// the proxy overwrites the first 160 bits with this contract's address,
/// so the guard sees (reactive, vault, action) and can authenticate it.
/// Funding: keep lREACT in this contract's own balance (plain transfer);
/// the system contract settles debt from it via pay() / coverDebt().
contract SentinelReactive is AbstractReactive {
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;

    /// @notice Verdicts at or above this score trigger a callback.
    uint256 public constant RISK_THRESHOLD = 70;

    /// @notice Callback gas limit. Minimum enforced by the network is
    /// 100,000. The Base Sepolia proxy withholds _extraGas (80,000) +
    /// _maxChargeGas (50,000) before forwarding, so 300,000 leaves ample
    /// room for VaultGuard.execute.
    uint64 public constant CALLBACK_GAS_LIMIT = 300_000;

    address public immutable oracle;
    uint256 public immutable verdictTopic0;
    address public owner;
    address public destination;

    uint256 public reactCount;
    uint256 public actedCount;
    uint256 public lastRiskScore;
    uint8 public lastAction;
    address public lastVault;
    uint256 public lastVerdictId;

    event VerdictSeen(uint256 indexed id, address indexed vault, uint256 riskScore, uint8 action, bool acted);
    event CallbackRequested(address indexed destination, address indexed vault, uint8 action);
    event DestinationSet(address indexed destination);

    error NotOwner(address caller);

    constructor(address oracle_, uint256 verdictTopic0_) {
        owner = msg.sender;
        oracle = oracle_;
        verdictTopic0 = verdictTopic0_;
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID, oracle_, verdictTopic0_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
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
    /// @dev Never revert: a reverting react() is still billed, and a
    /// below-threshold verdict is a normal outcome, not an error.
    function react(LogRecord memory log_) external override onlySystem {
        if (log_.topic0 != verdictTopic0 || log_.opCode != 3) return;
        uint256 id = log_.topic1;
        address vault = address(uint160(log_.topic2));
        (uint256 riskScore, uint8 action, ) = abi.decode(log_.data, (uint256, uint8, string));

        reactCount++;
        lastRiskScore = riskScore;
        lastAction = action;
        lastVault = vault;
        lastVerdictId = id;

        bool acted = false;
        if (riskScore >= RISK_THRESHOLD && (action == 1 || action == 2) && destination != address(0)) {
            bytes memory payload = abi.encodeWithSignature("execute(address,address,uint8)", address(0), vault, action);
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: BASE_SEPOLIA_CHAIN_ID,
                    recipient: destination,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: payload
                })
            );
            acted = true;
            actedCount++;
            emit CallbackRequested(destination, vault, action);
        }
        emit VerdictSeen(id, vault, riskScore, action, acted);
    }
}
