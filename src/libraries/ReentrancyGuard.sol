// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ReentrancyGuard
/// @notice One storage slot standing between a token callback and a second
///         entry into a function that is mid-way through moving value. Applied
///         to everything that pays out of a vault or an encrypted balance.
abstract contract ReentrancyGuard {
    uint256 private constant _OPEN = 1;
    uint256 private constant _CLOSED = 2;

    uint256 private _gate = _OPEN;

    error Reentrancy();

    modifier nonReentrant() {
        if (_gate == _CLOSED) revert Reentrancy();
        _gate = _CLOSED;
        _;
        _gate = _OPEN;
    }
}
