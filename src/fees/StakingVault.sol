// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "../libraries/ReentrancyGuard.sol";
import "../libraries/ProtocolErrors.sol";

/// @title StakingVault
/// @notice Custody for staked $MANSA. Staking is what earns the deepest fee
///         reduction anywhere in the protocol: {FeeSchedule} counts staked
///         tokens at full weight where it counts merely-held tokens at less.
///         Locking tokens in here is the on-chain way of saying an account's
///         fortunes are tied to the protocol's.
///
/// @dev This contract holds $MANSA and tracks who staked how much. It issues no
///      rewards of its own — the benefit is entirely the discount that
///      {FeeSchedule} reads out of {stakedOf}. Exit is immediate and
///      unconditional; there is no lockup to wait out.
contract StakingVault is ReentrancyGuard {
    using SafeTransferLib for IERC20;

    /// @notice The $MANSA token held here.
    IERC20 public immutable mansa;

    mapping(address => uint256) public stakedOf;

    /// @notice When the account's current position began. Adding to a position
    ///         leaves it alone and only a full exit clears it, so it reads as
    ///         "continuously staked since" rather than "last touched".
    mapping(address => uint64) public stakedSince;

    uint256 public totalStaked;

    event Staked(address indexed account, uint256 amount, uint256 newBalance);
    event Unstaked(address indexed account, uint256 amount, uint256 newBalance);

    constructor(IERC20 mansa_) {
        if (address(mansa_) == address(0)) revert ZeroAddress();
        mansa = mansa_;
    }

    /// @notice Takes `amount` of $MANSA from the caller into the vault.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidSpendAmount();

        uint256 before = mansa.balanceOf(address(this));
        mansa.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = mansa.balanceOf(address(this)) - before;

        // Start the clock only when a position opens, so adding to a long-held
        // stake never makes it look like it began today.
        if (stakedOf[msg.sender] == 0) {
            stakedSince[msg.sender] = uint64(block.timestamp);
        }
        stakedOf[msg.sender] += received;
        totalStaked += received;

        emit Staked(msg.sender, received, stakedOf[msg.sender]);
    }

    /// @notice Returns `amount` of $MANSA to the caller, immediately.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidSpendAmount();
        uint256 bal = stakedOf[msg.sender];
        if (amount > bal) revert InsufficientStakedBalance();

        unchecked {
            stakedOf[msg.sender] = bal - amount;
        }
        totalStaked -= amount;

        // Leaving entirely closes the position; staking again starts over.
        if (stakedOf[msg.sender] == 0) {
            stakedSince[msg.sender] = 0;
        }

        mansa.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, stakedOf[msg.sender]);
    }
}
