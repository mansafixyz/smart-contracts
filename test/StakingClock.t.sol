// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StakingVault} from "../src/fees/StakingVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import "../src/libraries/ProtocolErrors.sol";

contract StakingClockTest is Test {
    StakingVault staking;
    MockERC20 mansafi;

    address gwen = makeAddr("gwen");

    function setUp() public {
        mansafi = new MockERC20("MansaFi", "MANSA", 18);
        staking = new StakingVault(IERC20(address(mansafi)));

        mansafi.mint(gwen, 1_000e18);
        vm.prank(gwen);
        mansafi.approve(address(staking), type(uint256).max);
    }

    function test_top_up_keeps_the_original_clock() public {
        vm.prank(gwen);
        staking.stake(100e18);
        uint64 opened = staking.stakedSince(gwen);
        assertEq(opened, uint64(block.timestamp));

        // A year on the position is larger, yet it has not forgotten when it began.
        vm.warp(block.timestamp + 365 days);
        vm.prank(gwen);
        staking.stake(50e18);

        assertEq(staking.stakedOf(gwen), 150e18);
        assertEq(staking.stakedSince(gwen), opened);
    }

    function test_partial_unstake_keeps_the_clock() public {
        vm.prank(gwen);
        staking.stake(100e18);
        uint64 opened = staking.stakedSince(gwen);

        vm.warp(block.timestamp + 30 days);
        vm.prank(gwen);
        staking.unstake(40e18);

        assertEq(staking.stakedOf(gwen), 60e18);
        assertEq(staking.stakedSince(gwen), opened);
    }

    function test_full_exit_clears_the_clock_and_restake_starts_fresh() public {
        vm.prank(gwen);
        staking.stake(100e18);

        vm.warp(block.timestamp + 30 days);
        vm.prank(gwen);
        staking.unstake(100e18);
        assertEq(staking.stakedSince(gwen), 0);

        // Returning after a full exit starts a fresh position, and a fresh clock.
        vm.warp(block.timestamp + 7 days);
        vm.prank(gwen);
        staking.stake(10e18);
        assertEq(staking.stakedSince(gwen), uint64(block.timestamp));
    }

    function test_unstake_all_closes_the_position() public {
        vm.startPrank(gwen);
        staking.stake(300e18);
        staking.stake(200e18);
        staking.unstakeAll();
        vm.stopPrank();

        assertEq(staking.stakedOf(gwen), 0);
        assertEq(staking.stakedSince(gwen), 0);
        assertEq(staking.totalStaked(), 0);
        assertEq(mansafi.balanceOf(gwen), 1_000e18);
    }

    function test_unstake_all_with_nothing_staked_reverts() public {
        vm.expectRevert(InvalidSpendAmount.selector);
        vm.prank(gwen);
        staking.unstakeAll();
    }
}
