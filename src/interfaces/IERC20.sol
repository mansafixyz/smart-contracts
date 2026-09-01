// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IERC20
/// @notice The subset of ERC-20 this protocol actually calls, covering USDG and
///         any other settlement asset it moves on Robinhood Chain. Kept narrow
///         on purpose: a smaller surface is a smaller set of assumptions about
///         tokens whose implementations we do not control.
interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}
