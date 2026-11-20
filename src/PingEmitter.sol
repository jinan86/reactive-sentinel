// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title PingEmitter — minimal origin contract for the Sentinel hello-world loop.
/// @notice Deployed on Base Sepolia. Emits Ping events that the Lasna reactive
/// contract subscribes to. This is the Phase 1 de-risk contract, not the
/// Sentinel vault.
contract PingEmitter {
    event Ping(address indexed sender, uint256 value, uint256 indexed nonce);

    uint256 public nonce;

    /// @notice Emit a Ping event. `value` travels in `data`, `sender` and
    /// `nonce` are indexed topics (LOG3).
    function ping(uint256 value) external {
        nonce++;
        emit Ping(msg.sender, value, nonce);
    }
}
