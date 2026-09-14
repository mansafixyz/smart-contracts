// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeSchedule} from "../src/fees/FeeSchedule.sol";
import {StakingVault} from "../src/fees/StakingVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import "../src/libraries/ProtocolErrors.sol";

contract FeeScheduleAuthorityTest is Test {
    FeeSchedule fees;

    address admin = makeAddr("admin");
    address multisig = makeAddr("multisig");
    address mallory = makeAddr("mallory");

    function setUp() public {
        MockERC20 mansafi = new MockERC20("MansaFi", "MANSA", 18);
        StakingVault staking = new StakingVault(IERC20(address(mansafi)));
        fees = new FeeSchedule(admin, IERC20(address(mansafi)), staking);
    }

    function test_handoff_completes_only_after_acceptance() public {
        vm.prank(admin);
        fees.beginAuthorityTransfer(multisig);

        // A nomination on its own is inert; the incumbent still sets the prices.
        assertEq(fees.authority(), admin);
        assertEq(fees.pendingAuthority(), multisig);
        vm.prank(admin);
        fees.setSchedule(20, 5_000_000, 5_000);

        vm.prank(multisig);
        fees.acceptAuthority();
        assertEq(fees.authority(), multisig);
        assertEq(fees.pendingAuthority(), address(0));

        // The role has moved: the successor prices fees, the predecessor cannot.
        vm.prank(multisig);
        fees.setSchedule(10, 5_000_000, 5_000);
        vm.expectRevert(Unauthorized.selector);
        vm.prank(admin);
        fees.setSchedule(30, 5_000_000, 5_000);
    }

    function test_only_the_nominee_can_accept() public {
        vm.prank(admin);
        fees.beginAuthorityTransfer(multisig);

        vm.expectRevert(FeeSchedule.NotPendingAuthority.selector);
        vm.prank(mallory);
        fees.acceptAuthority();
    }

    function test_only_authority_can_nominate() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(mallory);
        fees.beginAuthorityTransfer(mallory);
    }

    function test_zero_nomination_cancels_a_pending_handoff() public {
        vm.startPrank(admin);
        fees.beginAuthorityTransfer(multisig);
        fees.beginAuthorityTransfer(address(0));
        vm.stopPrank();

        vm.expectRevert(FeeSchedule.NotPendingAuthority.selector);
        vm.prank(multisig);
        fees.acceptAuthority();
        assertEq(fees.authority(), admin);
    }
}
