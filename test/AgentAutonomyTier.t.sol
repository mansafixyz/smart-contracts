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

contract AgentAutonomyTierTest is Test {
    ProtocolAuthority protocol;
    AccountRegistry registry;
    AgentController agents;
    MockERC20 usdg;

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address signer = makeAddr("signer");
    address vendor = makeAddr("vendor");

    uint256 constant USDG_ONE = 1e6;

    function usd(uint256 dollars) internal pure returns (uint256) {
        return dollars * USDG_ONE;
    }

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);

        vm.prank(admin);
        protocol = new ProtocolAuthority(compliance);
        registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        agents = new AgentController(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
        usdg.mint(gwen, usd(1_000));
    }

    /// One policy across all three tiers: $10 a payment, $50 a day, approval over $5.
    function _createAgent(AgentController.AutonomyTier tier) internal returns (uint256 agentId) {
        address[] memory none = new address[](0);
        vm.prank(gwen);
        agentId = agents.createAgent(
            signer, "coding-assistant", tier, address(usdg), usd(10), usd(50), usd(5), none, false
        );
        vm.startPrank(gwen);
        usdg.approve(address(agents), type(uint256).max);
        agents.fundAgent(agentId, usd(100));
        vm.stopPrank();
    }

    // ── Supervised ───────────────────────────────────────────────────────────

    function test_supervised_agent_cannot_settle_directly() public {
        uint256 agentId = _createAgent(AgentController.AutonomyTier.Supervised);

        // Even pocket change, far beneath the threshold, waits for a person.
        vm.expectRevert(TierRequiresApproval.selector);
        vm.prank(signer);
        agents.payInvoice(agentId, vendor, usd(1), bytes32(0));
    }

    function test_supervised_agent_queues_below_the_threshold() public {
        uint256 agentId = _createAgent(AgentController.AutonomyTier.Supervised);

        vm.prank(signer);
        uint256 pendingId = agents.queueInvoice(agentId, vendor, usd(1), bytes32(0), bytes32(0));

        vm.prank(gwen);
        agents.approvePending(agentId, pendingId);
        assertEq(usdg.balanceOf(vendor), usd(1));
        assertEq(agents.vaultBalance(agentId), usd(99));
    }

    // ── SemiAutonomous ───────────────────────────────────────────────────────

    function test_semi_autonomous_keeps_the_hitl_boundary() public {
        uint256 agentId = _createAgent(AgentController.AutonomyTier.SemiAutonomous);

        // Beneath the threshold it goes through; past it, it waits.
        vm.prank(signer);
        agents.payInvoice(agentId, vendor, usd(5), bytes32(0));
        assertEq(usdg.balanceOf(vendor), usd(5));

        vm.expectRevert(AmountExceedsHitlThreshold.selector);
        vm.prank(signer);
        agents.payInvoice(agentId, vendor, usd(6), bytes32(0));

        vm.expectRevert(AmountWithinHitlThreshold.selector);
        vm.prank(signer);
        agents.queueInvoice(agentId, vendor, usd(5), bytes32(0), bytes32(0));
    }

    // ── FullyAutonomous ──────────────────────────────────────────────────────

    function test_fully_autonomous_settles_above_the_threshold() public {
        uint256 agentId = _createAgent(AgentController.AutonomyTier.FullyAutonomous);

        vm.prank(signer);
        agents.payInvoice(agentId, vendor, usd(8), bytes32(0));
        assertEq(usdg.balanceOf(vendor), usd(8));
        assertEq(agents.vaultBalance(agentId), usd(92));
    }

    function test_fully_autonomous_still_bound_by_policy_limits() public {
        uint256 agentId = _createAgent(AgentController.AutonomyTier.FullyAutonomous);

        // Full autonomy stretches how much settles unattended. It leaves the
        // per-payment and daily ceilings exactly where they were.
        vm.expectRevert(PerTransactionLimitExceeded.selector);
        vm.prank(signer);
        agents.payInvoice(agentId, vendor, usd(11), bytes32(0));

        vm.startPrank(signer);
        for (uint256 i; i < 5; ++i) {
            agents.payInvoice(agentId, vendor, usd(10), bytes32(0));
        }
        vm.expectRevert(DailyLimitExceeded.selector);
        agents.payInvoice(agentId, vendor, usd(1), bytes32(0));
        vm.stopPrank();
    }

    function test_fully_autonomous_may_still_ask_for_approval() public {
        uint256 agentId = _createAgent(AgentController.AutonomyTier.FullyAutonomous);

        // The fully autonomous tier may still ask, whatever the figure.
        vm.prank(signer);
        uint256 pendingId = agents.queueInvoice(agentId, vendor, usd(2), bytes32(0), bytes32(0));

        vm.prank(gwen);
        agents.approvePending(agentId, pendingId);
        assertEq(usdg.balanceOf(vendor), usd(2));
    }
}
