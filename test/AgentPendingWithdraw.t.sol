// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../src/ProtocolAuthority.sol";
import {AccountRegistry} from "../src/AccountRegistry.sol";
import {AgentController} from "../src/AgentController.sol";
import {IProtocolAuthority} from "../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../src/interfaces/IAccountRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import "../src/libraries/ProtocolErrors.sol";

contract AgentPendingWithdrawTest is Test {
    ProtocolAuthority protocol;
    AccountRegistry registry;
    AgentController agents;
    MockERC20 usdg;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address signer = makeAddr("signer");
    address vendor = makeAddr("vendor");

    uint256 agentId;

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        protocol = new ProtocolAuthority(compliance);
        registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        agents = new AgentController(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
        usdg.mint(gwen, 1_000e6);

        address[] memory none = new address[](0);
        vm.startPrank(gwen);
        agentId = agents.createAgent(
            signer,
            "coding-assistant",
            AgentController.AutonomyTier.SemiAutonomous,
            address(usdg),
            10e6,
            50e6,
            5e6,
            none,
            false
        );
        usdg.approve(address(agents), 100e6);
        agents.fundAgent(agentId, 100e6);
        vm.stopPrank();
    }

    function _queue() internal returns (uint256) {
        vm.prank(signer);
        return agents.queueInvoice(agentId, vendor, 8e6, keccak256("inv"), bytes32(0));
    }

    function test_signer_can_withdraw_its_own_queued_spend() public {
        uint256 pendingId = _queue();
        uint256 vaultBefore = agents.vaultBalance(agentId);

        vm.prank(signer);
        agents.withdrawPending(agentId, pendingId);

        assertFalse(agents.getPending(agentId, pendingId).exists);
        assertEq(agents.vaultBalance(agentId), vaultBefore);

        // Gone means gone: the owner can no longer approve it.
        vm.expectRevert(PendingApprovalNotFound.selector);
        vm.prank(gwen);
        agents.approvePending(agentId, pendingId);
    }

    function test_only_the_signer_may_withdraw() public {
        uint256 pendingId = _queue();

        vm.expectRevert(UnauthorizedAgentSigner.selector);
        vm.prank(gwen);
        agents.withdrawPending(agentId, pendingId);

        vm.expectRevert(UnauthorizedAgentSigner.selector);
        vm.prank(vendor);
        agents.withdrawPending(agentId, pendingId);
    }

    function test_withdrawing_an_unknown_record_reverts() public {
        vm.expectRevert(PendingApprovalNotFound.selector);
        vm.prank(signer);
        agents.withdrawPending(agentId, 42);
    }

    function test_open_pending_ids_skip_settled_and_dropped_records() public {
        uint256 a = _queue();
        uint256 b = _queue();
        uint256 c = _queue();
        uint256 d = _queue();

        vm.prank(gwen);
        agents.approvePending(agentId, a);
        vm.prank(gwen);
        agents.rejectPending(agentId, c);

        uint256[] memory open = agents.openPendingIds(agentId);
        assertEq(open.length, 2);
        assertEq(open[0], b);
        assertEq(open[1], d);
    }

    function test_open_pending_ids_is_empty_for_a_quiet_agent() public view {
        assertEq(agents.openPendingIds(agentId).length, 0);
    }
}
