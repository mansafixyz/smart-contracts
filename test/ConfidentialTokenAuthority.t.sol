// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ConfidentialToken} from "../src/confidential/ConfidentialToken.sol";
import {StubTransferVerifier} from "../src/confidential/StubTransferVerifier.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import "../src/libraries/ProtocolErrors.sol";

contract ConfidentialTokenAuthorityTest is Test {
    ConfidentialToken confidential;
    MockERC20 usdg;

    address admin = makeAddr("admin");
    address multisig = makeAddr("multisig");
    address mallory = makeAddr("mallory");

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        confidential =
            new ConfidentialToken(IERC20(address(usdg)), new StubTransferVerifier(), admin);
    }

    function test_handoff_completes_only_after_acceptance() public {
        vm.prank(admin);
        confidential.beginAuthorityTransfer(multisig);

        // Naming a successor grants it nothing; the incumbent still rules here.
        assertEq(confidential.authority(), admin);
        assertEq(confidential.pendingAuthority(), multisig);
        vm.prank(admin);
        confidential.setPaused(true);

        vm.prank(multisig);
        confidential.acceptAuthority();
        assertEq(confidential.authority(), multisig);
        assertEq(confidential.pendingAuthority(), address(0));

        // The role has changed hands: the successor acts, the predecessor cannot.
        vm.prank(multisig);
        confidential.setPaused(false);
        vm.expectRevert(Unauthorized.selector);
        vm.prank(admin);
        confidential.setPaused(true);
    }

    function test_only_the_nominee_can_accept() public {
        vm.prank(admin);
        confidential.beginAuthorityTransfer(multisig);

        vm.expectRevert(ConfidentialToken.NotPendingAuthority.selector);
        vm.prank(mallory);
        confidential.acceptAuthority();
    }

    function test_only_authority_can_nominate() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(mallory);
        confidential.beginAuthorityTransfer(mallory);
    }

    function test_zero_nomination_cancels_a_pending_handoff() public {
        vm.startPrank(admin);
        confidential.beginAuthorityTransfer(multisig);
        confidential.beginAuthorityTransfer(address(0));
        vm.stopPrank();

        vm.expectRevert(ConfidentialToken.NotPendingAuthority.selector);
        vm.prank(multisig);
        confidential.acceptAuthority();
        assertEq(confidential.authority(), admin);
    }
}
