// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IConfidentialTransferVerifier} from "./IConfidentialTransferVerifier.sol";

/// @title StubTransferVerifier
/// @notice A placeholder standing where the Groth16 verifier will go. It waves
///         every proof through, and exists purely so the confidential token can
///         be driven end to end on a local node or a testnet before the real
///         circuits are ready.
///
/// @dev Never deploy this to production. While it is installed the token has no
///      confidentiality guarantee of any kind, because nothing is being checked.
///      Point {ConfidentialToken.setVerifier} at the audited verifier before any
///      real value goes in.
contract StubTransferVerifier is IConfidentialTransferVerifier {
    function verifyTransfer(bytes calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }

    function verifyWithdraw(bytes calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }
}
