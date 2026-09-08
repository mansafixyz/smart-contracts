// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title AltBn128
/// @notice Curve arithmetic on alt_bn128 (BN254), the ground the confidential
///         token stands on. Additions and scalar multiplications are delegated
///         to the EVM precompiles at 0x06 and 0x07, which Robinhood Chain
///         inherits from the Arbitrum Nitro stack, so encrypted balances can be
///         adjusted on-chain without ever being opened.
///
/// @dev An ElGamal ciphertext in the token contract is a pair of points on this
///      curve. Adding two ciphertexts is nothing more than adding their
///      components pairwise, and that property is the entire trick: a verified
///      transfer debits one balance and credits another while the amount stays
///      sealed inside the arithmetic.
library AltBn128 {
    /// @notice A G1 point. The identity is written (0, 0), matching what the
    ///         precompiles expect.
    struct Point {
        uint256 x;
        uint256 y;
    }

    /// @dev The curve's field modulus.
    uint256 internal constant FIELD_MODULUS =
        21888242871839275222246405745257275088696311157297823662689037894645226208583;

    error ECAddFailed();
    error ECMulFailed();

    /// @notice The standard G1 generator, the base against which a plaintext `m`
    ///         is represented as `m * G`.
    function generator() internal pure returns (Point memory) {
        return Point(1, 2);
    }

    /// @notice The identity element, or point at infinity.
    function zero() internal pure returns (Point memory) {
        return Point(0, 0);
    }

    /// @notice Whether `p` genuinely lies on `y^2 = x^3 + 3` with both
    ///         coordinates inside the field. Note that the identity `(0, 0)`
    ///         fails this test, which is intentional; a caller wanting to admit
    ///         it must handle that case itself.
    function isOnCurve(Point memory p) internal pure returns (bool) {
        if (p.x >= FIELD_MODULUS || p.y >= FIELD_MODULUS) return false;
        uint256 lhs = mulmod(p.y, p.y, FIELD_MODULUS);
        uint256 rhs =
            addmod(mulmod(mulmod(p.x, p.x, FIELD_MODULUS), p.x, FIELD_MODULUS), 3, FIELD_MODULUS);
        return lhs == rhs;
    }

    /// @notice The additive inverse of `p`, such that adding the two yields the
    ///         identity. This is how an amount gets subtracted from an encrypted
    ///         balance.
    function negate(Point memory p) internal pure returns (Point memory) {
        if (p.x == 0 && p.y == 0) return Point(0, 0);
        return Point(p.x, FIELD_MODULUS - (p.y % FIELD_MODULUS));
    }

    /// @notice Adds two points through the 0x06 precompile.
    function add(Point memory a, Point memory b) internal view returns (Point memory r) {
        uint256[4] memory input = [a.x, a.y, b.x, b.y];
        bool ok;
        assembly {
            ok := staticcall(gas(), 0x06, input, 0x80, r, 0x40)
        }
        if (!ok) revert ECAddFailed();
    }

    /// @notice Multiplies a point by a scalar through the 0x07 precompile.
    function mul(Point memory p, uint256 s) internal view returns (Point memory r) {
        uint256[3] memory input = [p.x, p.y, s];
        bool ok;
        assembly {
            ok := staticcall(gas(), 0x07, input, 0x60, r, 0x40)
        }
        if (!ok) revert ECMulFailed();
    }

    /// @notice Represents a plaintext scalar `m` as `m * G`, the form a deposit
    ///         folds into an encrypted balance.
    function encode(uint256 m) internal view returns (Point memory) {
        return mul(generator(), m);
    }
}
