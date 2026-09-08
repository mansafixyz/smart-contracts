// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IConfidentialTransferVerifier
/// @notice What the token contract expects of a proof verifier. A real
///         implementation is a Groth16 verifier generated from the protocol's
///         circuits — Circom or Noir — and deployed on its own, which is what
///         allows the proof system to be replaced without disturbing a single
///         stored balance.
///
/// @dev `publicSignals` is the flattened, circuit-specific list of public
///      inputs: the parties' ElGamal public keys, the ciphertexts in play, and
///      the encrypted deltas. The token contract forwards it untouched, since
///      only the verifier knows how it is laid out.
interface IConfidentialTransferVerifier {
    /// @notice Checks a transfer proof. True only when both deltas encrypt one
    ///         and the same non-negative amount and the sender's balance
    ///         survives the subtraction.
    function verifyTransfer(bytes calldata proof, uint256[] calldata publicSignals)
        external
        view
        returns (bool);

    /// @notice Checks a withdrawal proof. True only when the encrypted balance
    ///         genuinely covers what is being unwrapped.
    function verifyWithdraw(bytes calldata proof, uint256[] calldata publicSignals)
        external
        view
        returns (bool);
}
