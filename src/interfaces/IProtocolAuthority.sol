// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IProtocolAuthority
/// @notice What every other module needs to know about the shared control
///         surface: who administers the protocol, who may attest identity, is
///         the circuit breaker open, and where fees are routed.
/// @dev Deliberately read-only. Modules consult this and never mutate it, so
///      there is exactly one contract that can change how the protocol behaves.
interface IProtocolAuthority {
    function authority() external view returns (address);
    function complianceAuthority() external view returns (address);
    function paused() external view returns (bool);

    /// @notice Destination for protocol fees. The zero address means no fee is
    ///         charged anywhere.
    function treasury() external view returns (address);

    /// @notice The IFeeSchedule that prices fees and applies $MANSA discounts.
    ///         Zero means fees are off. Typed as a plain address so consumers
    ///         are not forced into an import they may not otherwise need.
    function feeSchedule() external view returns (address);
}
