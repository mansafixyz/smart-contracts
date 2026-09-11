// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IFeeSchedule
/// @notice The on-chain expression of "being invested in the protocol costs you
///         less to use it". Every contract that moves value prices its fee
///         through here, and clients call the same views to show someone their
///         rate before they commit to anything.
///
/// @dev The discount tracks how much $MANSA an account is tied up in: tokens
///      staked in {StakingVault} count fully, tokens merely sitting in a wallet
///      count for less, and the combined figure places the account on a discount
///      curve applied to the base rate.
interface IFeeSchedule {
    /// @notice What a `payer` owes on a transfer of `amount`, after whatever
    ///         discount their $MANSA earns them.
    /// @param payer Account whose holdings and stake determine the discount.
    /// @param amount The transfer's full size, denominated in settlement-token units.
    /// @return feeAmount What is owed, in those same units.
    /// @return effectiveBps The rate that actually resulted, for display.
    function quoteFee(address payer, uint256 amount)
        external
        view
        returns (uint256 feeAmount, uint256 effectiveBps);

    /// @notice The discount, in basis points off the base rate, that `account`
    ///         currently earns.
    function discountBpsOf(address account) external view returns (uint256);

    /// @notice The weighted $MANSA figure placing `account` on the curve: staked
    ///         at full weight, held at a fraction of it.
    function loyaltyWeightOf(address account) external view returns (uint256);
}
