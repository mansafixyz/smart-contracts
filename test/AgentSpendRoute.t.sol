// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../src/ProtocolAuthority.sol";
import {AccountRegistry} from "../src/AccountRegistry.sol";
import {AgentController} from "../src/AgentController.sol";
import {IProtocolAuthority} from "../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../src/interfaces/IAccountRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract AgentSpendRouteTest is Test {
    ProtocolAuthority protocol;
    AccountRegistry registry;
    AgentController agents;
    MockERC20 usdg;

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address signer = makeAddr("signer");
    address vendor = makeAddr("vendor");
    address stranger = makeAddr("stranger");

    uint256 agentId;

    function usd(uint256 d) internal pure returns (uint256) {
        return d * 1e6;
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

        address[] memory allowed = new address[](1);
        allowed[0] = vendor;
        vm.startPrank(gwen);
        agentId = agents.createAgent(
            signer,
            "coding-assistant",
            AgentController.AutonomyTier.SemiAutonomous,
            address(usdg),
            usd(10), // per tx
            usd(50), // per day
            usd(5), // hitl threshold
            allowed,
            true
        );
        usdg.approve(address(agents), usd(100));
        agents.fundAgent(agentId, usd(100));
        vm.stopPrank();
    }

    function _route(address to, uint256 amount) internal view returns (AgentController.SpendRoute) {
        return agents.routeFor(agentId, to, amount);
    }

    function assertRoute(AgentController.SpendRoute got, AgentController.SpendRoute want)
        internal
        pure
    {
        assertEq(uint8(got), uint8(want));
    }

    function test_within_threshold_settles() public view {
        assertRoute(_route(vendor, usd(5)), AgentController.SpendRoute.Settles);
    }

    function test_above_threshold_queues() public view {
        assertRoute(_route(vendor, usd(6)), AgentController.SpendRoute.Queues);
    }

    function test_over_per_tx_limit_is_refused() public view {
        assertRoute(_route(vendor, usd(11)), AgentController.SpendRoute.Refused);
    }

    function test_recipient_off_allowlist_is_refused() public view {
        assertRoute(_route(stranger, usd(5)), AgentController.SpendRoute.Refused);
    }

    function test_exhausted_day_is_refused_until_window_rolls() public {
        for (uint256 i; i < 10; ++i) {
            vm.prank(signer);
            agents.payInvoice(agentId, vendor, usd(5), bytes32(0));
        }
        assertRoute(_route(vendor, usd(1)), AgentController.SpendRoute.Refused);

        vm.warp(block.timestamp + 1 days);
        assertRoute(_route(vendor, usd(1)), AgentController.SpendRoute.Settles);
    }

    function test_paused_agent_or_protocol_is_refused() public {
        vm.prank(admin);
        protocol.setPause(true);
        assertRoute(_route(vendor, usd(5)), AgentController.SpendRoute.Refused);
        vm.prank(admin);
        protocol.setPause(false);

        vm.prank(gwen);
        agents.setAgentStatus(agentId, AgentController.AgentStatus.Paused);
        assertRoute(_route(vendor, usd(5)), AgentController.SpendRoute.Refused);
    }

    function test_supervised_agent_always_queues() public {
        address[] memory none = new address[](0);
        vm.prank(gwen);
        uint256 supervised = agents.createAgent(
            signer,
            "intern",
            AgentController.AutonomyTier.Supervised,
            address(usdg),
            usd(10),
            usd(50),
            usd(5),
            none,
            false
        );
        assertRoute(agents.routeFor(supervised, vendor, usd(1)), AgentController.SpendRoute.Queues);
    }

    function test_unknown_agent_is_refused() public view {
        assertRoute(agents.routeFor(999, vendor, usd(1)), AgentController.SpendRoute.Refused);
    }
}
