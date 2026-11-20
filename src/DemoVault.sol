// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DemoToken } from "./DemoToken.sol";

/// @title DemoVault — demo vault watched by the Sentinel AI service.
/// @notice Holds DemoToken deposits on Base Sepolia. Emits Deposit,
/// Withdrawal, LargeWithdrawal and PriceDeviation events that the
/// off-chain AI service scores. A VaultGuard (wired by the owner) can
/// freeze withdrawals and rescue all funds to a safe vault; only the
/// owner (human) can unfreeze. Demo-only, no real value.
contract DemoVault {
    DemoToken public immutable token;

    address public owner;
    address public guard;
    address public safeVault;

    bool public frozen;
    int256 public mockPrice; // 8 decimals, e.g. 100_00000000 = $100

    /// @notice Withdrawals above this share of TVL count as "large".
    uint256 public constant LARGE_SHARE_BPS = 2500; // 25%
    /// @notice Price moves above this count as a deviation.
    uint256 public constant DEVIATION_BPS = 500; // 5%

    event Deposit(address indexed user, uint256 amount, uint256 balance);
    event Withdrawal(address indexed user, uint256 amount, uint256 balance);
    event LargeWithdrawal(address indexed user, uint256 amount, uint256 shareBps);
    event PriceDeviation(int256 oldPrice, int256 newPrice, uint256 deviationBps);
    event Frozen(address indexed by);
    event Unfrozen(address indexed by);
    event Rescued(address indexed to, uint256 amount);
    event GuardSet(address indexed guard);
    event SafeVaultSet(address indexed safeVault);

    error NotOwner(address caller);
    error NotGuard(address caller);
    error FrozenVault();
    error NotFrozen();
    error NoSafeVault();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    modifier onlyGuard() {
        if (msg.sender != guard) revert NotGuard(msg.sender);
        _;
    }

    constructor(DemoToken token_, int256 initialPrice_) {
        owner = msg.sender;
        token = token_;
        mockPrice = initialPrice_;
    }

    function setGuard(address guard_) external onlyOwner {
        guard = guard_;
        emit GuardSet(guard_);
    }

    function setSafeVault(address safeVault_) external onlyOwner {
        safeVault = safeVault_;
        emit SafeVaultSet(safeVault_);
    }

    /// @notice Demo price feed: the owner moves the mock price. A move
    /// bigger than DEVIATION_BPS emits PriceDeviation for the AI service.
    function setPrice(int256 newPrice_) external onlyOwner {
        int256 old = mockPrice;
        mockPrice = newPrice_;
        uint256 devBps = _bpsDiff(old, newPrice_);
        if (devBps >= DEVIATION_BPS) emit PriceDeviation(old, newPrice_, devBps);
    }

    function deposit(uint256 amount) external {
        if (frozen) revert FrozenVault();
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Deposit(msg.sender, amount, token.balanceOf(address(this)));
    }

    function withdraw(uint256 amount) external {
        if (frozen) revert FrozenVault();
        uint256 tvlBefore = token.balanceOf(address(this));
        require(token.transfer(msg.sender, amount), "transfer failed");
        uint256 shareBps = tvlBefore == 0 ? 0 : (amount * 10000) / tvlBefore;
        emit Withdrawal(msg.sender, amount, token.balanceOf(address(this)));
        if (shareBps >= LARGE_SHARE_BPS) emit LargeWithdrawal(msg.sender, amount, shareBps);
    }

    /// @notice Freeze withdrawals. Guard (via reactive callback) or owner.
    function freeze() external {
        if (msg.sender != guard && msg.sender != owner) revert NotGuard(msg.sender);
        if (frozen) return;
        frozen = true;
        emit Frozen(msg.sender);
    }

    /// @notice Unfreeze. Human (owner) only — the guard can never unfreeze.
    function unfreeze() external onlyOwner {
        frozen = false;
        emit Unfrozen(msg.sender);
    }

    /// @notice Rescue all funds to the safe vault. Guard only, requires
    /// the vault to be frozen first (freeze-then-rescue order).
    function rescue() external onlyGuard {
        if (!frozen) revert NotFrozen();
        if (safeVault == address(0)) revert NoSafeVault();
        uint256 amount = token.balanceOf(address(this));
        require(token.transfer(safeVault, amount), "transfer failed");
        emit Rescued(safeVault, amount);
    }

    function _bpsDiff(int256 a, int256 b) internal pure returns (uint256) {
        if (a == 0) return b == 0 ? 0 : type(uint256).max;
        int256 diff = b - a;
        if (diff < 0) diff = -diff;
        return (uint256(diff) * 10000) / uint256(a < 0 ? -a : a);
    }
}
