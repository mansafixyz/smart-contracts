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

contract AgentSignerRotationTest is Test {
    ProtocolAuthority protocol;
    AccountRegistry registry;
    AgentController agents;
    MockERC20 usdg;

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address vendor = makeAddr("vendor");
    address oldSigner = makeAddr("oldSigner");
    address newSigner = makeAddr("newSigner");

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

    function _createAgent() internal returns (uint256 agentId) {
        address[] memory none = new address[](0);
        vm.prank(gwen);
        agentId = agents.createAgent(
            oldSigner,
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

    function test_owner_rotates_signer() public {
        uint256 agentId = _createAgent();

        vm.prank(gwen);
        agents.rotateAgentSigner(agentId, newSigner);
        assertEq(agents.getAgent(agentId).agentSigner, newSigner);
    }

    function test_rotated_signer_can_pay_old_cannot() public {
        uint256 agentId = _createAgent();

        vm.prank(gwen);
        agents.rotateAgentSigner(agentId, newSigner);

        // Nothing answers to the leaked key any more.
        vm.expectRevert(UnauthorizedAgentSigner.selector);
        vm.prank(oldSigner);
        agents.payInvoice(agentId, vendor, usd(4), bytes32(0));

        // The replacement signs against an unchanged vault and policy.
        vm.prank(newSigner);
        agents.payInvoice(agentId, vendor, usd(4), bytes32(0));
        assertEq(usdg.balanceOf(vendor), usd(4));
        assertEq(agents.vaultBalance(agentId), usd(96));
    }

    function test_only_owner_can_rotate() public {
        uint256 agentId = _createAgent();
        vm.expectRevert(UnauthorizedAgentOwner.selector);
        vm.prank(oldSigner);
        agents.rotateAgentSigner(agentId, newSigner);
    }

    function test_rotate_to_zero_reverts() public {
        uint256 agentId = _createAgent();
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(gwen);
        agents.rotateAgentSigner(agentId, address(0));
    }

    function test_rotate_to_same_signer_reverts() public {
        uint256 agentId = _createAgent();
        vm.expectRevert(AgentController.SameSigner.selector);
        vm.prank(gwen);
        agents.rotateAgentSigner(agentId, oldSigner);
    }

    function test_cannot_rotate_revoked_agent() public {
        uint256 agentId = _createAgent();
        vm.startPrank(gwen);
        agents.revokeAgent(agentId);
        vm.expectRevert(AgentAlreadyRevoked.selector);
        agents.rotateAgentSigner(agentId, newSigner);
        vm.stopPrank();
    }

    function test_rotation_survives_pause_and_resume() public {
        uint256 agentId = _createAgent();

        vm.startPrank(gwen);
        agents.setAgentStatus(agentId, AgentController.AgentStatus.Paused);
        agents.rotateAgentSigner(agentId, newSigner);
        agents.setAgentStatus(agentId, AgentController.AgentStatus.Active);
        vm.stopPrank();

        vm.prank(newSigner);
        agents.payInvoice(agentId, vendor, usd(4), bytes32(0));
        assertEq(usdg.balanceOf(vendor), usd(4));
    }
}
