// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../src/ProtocolAuthority.sol";
import "../src/libraries/ProtocolErrors.sol";

contract ProtocolAuthorityTransferTest is Test {
    ProtocolAuthority protocol;

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address nextAdmin = makeAddr("nextAdmin");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.prank(admin);
        protocol = new ProtocolAuthority(compliance);
    }

    function test_only_authority_can_begin_transfer() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(stranger);
        protocol.beginAuthorityTransfer(nextAdmin);
    }

    function test_two_step_handoff() public {
        vm.prank(admin);
        protocol.beginAuthorityTransfer(nextAdmin);

        // Naming a successor hands over nothing by itself.
        assertEq(protocol.authority(), admin);
        assertEq(protocol.pendingAuthority(), nextAdmin);

        // Nobody but the nominee may claim it.
        vm.expectRevert(ProtocolAuthority.NotPendingAuthority.selector);
        vm.prank(stranger);
        protocol.acceptAuthority();

        vm.prank(nextAdmin);
        protocol.acceptAuthority();

        assertEq(protocol.authority(), nextAdmin);
        assertEq(protocol.pendingAuthority(), address(0));
    }

    function test_new_authority_can_pause_old_cannot() public {
        vm.prank(admin);
        protocol.beginAuthorityTransfer(nextAdmin);
        vm.prank(nextAdmin);
        protocol.acceptAuthority();

        vm.expectRevert(Unauthorized.selector);
        vm.prank(admin);
        protocol.setPause(true);

        vm.prank(nextAdmin);
        protocol.setPause(true);
        assertTrue(protocol.paused());
    }

    function test_pending_can_be_cancelled() public {
        vm.startPrank(admin);
        protocol.beginAuthorityTransfer(nextAdmin);
        protocol.beginAuthorityTransfer(address(0));
        vm.stopPrank();

        assertEq(protocol.pendingAuthority(), address(0));
        vm.expectRevert(ProtocolAuthority.NotPendingAuthority.selector);
        vm.prank(nextAdmin);
        protocol.acceptAuthority();
    }

    function test_direct_update_clears_pending() public {
        vm.startPrank(admin);
        protocol.beginAuthorityTransfer(nextAdmin);
        // Replacing the role outright cancels whatever handoff was under way.
        protocol.updateConfig(admin, compliance);
        vm.stopPrank();

        assertEq(protocol.pendingAuthority(), address(0));
        vm.expectRevert(ProtocolAuthority.NotPendingAuthority.selector);
        vm.prank(nextAdmin);
        protocol.acceptAuthority();
    }

    function test_compliance_authority_rotates_on_its_own() public {
        address vendor = makeAddr("vendor");

        vm.expectRevert(Unauthorized.selector);
        vm.prank(stranger);
        protocol.setComplianceAuthority(vendor);

        vm.expectRevert(ZeroAddress.selector);
        vm.prank(admin);
        protocol.setComplianceAuthority(address(0));

        // A handoff already underway is left exactly as it was.
        vm.prank(admin);
        protocol.beginAuthorityTransfer(nextAdmin);
        vm.prank(admin);
        protocol.setComplianceAuthority(vendor);

        assertEq(protocol.complianceAuthority(), vendor);
        assertEq(protocol.authority(), admin);
        assertEq(protocol.pendingAuthority(), nextAdmin);
    }
}
