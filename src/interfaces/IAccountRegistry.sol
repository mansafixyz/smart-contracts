// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IAccountRegistry
/// @notice The slice of the identity layer that the agent, request, and
///         disclosure modules depend on. Each of them needs to establish that a
///         caller actually holds an account here before letting that caller
///         create records pointing at one.
interface IAccountRegistry {
    enum KycTier {
        Unverified,
        Basic,
        Enhanced
    }

    function isRegistered(address owner) external view returns (bool);
    function handleOf(address owner) external view returns (string memory);
    function kycTierOf(address owner) external view returns (KycTier);
}
