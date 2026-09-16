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

contract AgentVaultDrawdownTest is Test {
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

    function _createFundedAgent() internal returns (uint256 agentId) {
        address[] memory none = new address[](0);
        vm.prank(gwen);
        agentId = agents.createAgent(
            signer,
            "coding-assistant",
            AgentController.AutonomyTier.SemiAutonomous,
            address(usdg),
            usd(10),
            usd(50),
            usd(5),
            none,
            false
        );
        vm.startPrank(gwen);
        usdg.approve(address(agents), type(uint256).max);
        agents.fundAgent(agentId, usd(100));
        vm.stopPrank();
    }

    function test_owner_draws_down_and_agent_keeps_running() public {
        uint256 agentId = _createFundedAgent();

        vm.prank(gwen);
        agents.withdrawFromAgent(agentId, usd(60));

        assertEq(agents.vaultBalance(agentId), usd(40));
        assertEq(usdg.balanceOf(gwen), usd(960));

        // Nothing about the agent moved: status, policy, and spending all intact.
        vm.prank(signer);
        agents.payInvoice(agentId, vendor, usd(4), bytes32(0));
        assertEq(usdg.balanceOf(vendor), usd(4));
        assertEq(agents.vaultBalance(agentId), usd(36));
    }

    function test_only_the_owner_can_draw_down() public {
        uint256 agentId = _createFundedAgent();

        // An agent has no route to drain its own vault.
        vm.expectRevert(UnauthorizedAgentOwner.selector);
        vm.prank(signer);
        agents.withdrawFromAgent(agentId, usd(1));
    }

    function test_cannot_draw_more_than_the_vault_holds() public {
        uint256 agentId = _createFundedAgent();

        vm.expectRevert(InsufficientVaultBalance.selector);
        vm.prank(gwen);
        agents.withdrawFromAgent(agentId, usd(101));

        vm.expectRevert(InvalidSpendAmount.selector);
        vm.prank(gwen);
        agents.withdrawFromAgent(agentId, 0);
    }

    function test_drawdown_stays_open_while_the_protocol_is_paused() public {
        uint256 agentId = _createFundedAgent();

        vm.prank(admin);
        protocol.setPause(true);

        // A freeze stops spending; it must not seal the owner's way out.
        vm.expectRevert(ProtocolPaused.selector);
        vm.prank(signer);
        agents.payInvoice(agentId, vendor, usd(4), bytes32(0));

        vm.prank(gwen);
        agents.withdrawFromAgent(agentId, usd(100));
        assertEq(agents.vaultBalance(agentId), 0);
        assertEq(usdg.balanceOf(gwen), usd(1_000));
    }

    function test_drawdown_works_on_a_paused_agent() public {
        uint256 agentId = _createFundedAgent();

        vm.startPrank(gwen);
        agents.setAgentStatus(agentId, AgentController.AgentStatus.Paused);
        agents.withdrawFromAgent(agentId, usd(25));
        vm.stopPrank();

        assertEq(agents.vaultBalance(agentId), usd(75));
    }
}
