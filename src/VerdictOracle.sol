// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title VerdictOracle — on-chain store for AI risk verdicts.
/// @notice The off-chain Sentinel Agent (writer key) scores DemoVault
/// events and writes a verdict here. The Lasna reactive contract
/// subscribes to the Verdict event. Actions: 0 = NONE, 1 = FREEZE,
/// 2 = RESCUE. Risk scores are 0-100. Demo-only, no real value.
contract VerdictOracle {
    uint8 public constant ACTION_NONE = 0;
    uint8 public constant ACTION_FREEZE = 1;
    uint8 public constant ACTION_RESCUE = 2;

    address public owner;
    address public writer;

    struct VerdictRecord {
        address vault;
        uint256 riskScore;
        uint8 action;
        string reasons;
        uint256 timestamp;
    }

    VerdictRecord[] public verdicts;

    event Verdict(uint256 indexed id, address indexed vault, uint256 riskScore, uint8 action, string reasons);
    event WriterSet(address indexed writer);

    error NotOwner(address caller);
    error NotWriter(address caller);
    error InvalidScore(uint256 score);
    error InvalidAction(uint8 action);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    constructor(address writer_) {
        owner = msg.sender;
        writer = writer_;
    }

    function setWriter(address writer_) external onlyOwner {
        writer = writer_;
        emit WriterSet(writer_);
    }

    /// @notice Write a verdict. Only the AI service writer key.
    function writeVerdict(address vault_, uint256 riskScore_, uint8 action_, string calldata reasons_)
        external
        returns (uint256 id)
    {
        if (msg.sender != writer) revert NotWriter(msg.sender);
        if (riskScore_ > 100) revert InvalidScore(riskScore_);
        if (action_ > ACTION_RESCUE) revert InvalidAction(action_);
        id = verdicts.length;
        verdicts.push(
            VerdictRecord({
                vault: vault_,
                riskScore: riskScore_,
                action: action_,
                reasons: reasons_,
                timestamp: block.timestamp
            })
        );
        emit Verdict(id, vault_, riskScore_, action_, reasons_);
    }

    function verdictCount() external view returns (uint256) {
        return verdicts.length;
    }
}
