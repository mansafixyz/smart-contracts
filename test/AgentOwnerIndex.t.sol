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

contract AgentOwnerIndexTest is Test {
    ProtocolAuthority protocol;
    AccountRegistry registry;
    AgentController agents;
    MockERC20 usdg;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address felix = makeAddr("felix");
    address signer = makeAddr("signer");

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        protocol = new ProtocolAuthority(compliance);
        registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        agents = new AgentController(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
        vm.prank(felix);
        registry.createProfile("felix", AccountRegistry.AccountKind.Personal);
    }

    function _create(address owner, string memory label) internal returns (uint256) {
        address[] memory none = new address[](0);
        vm.prank(owner);
        return agents.createAgent(
            signer,
            label,
            AgentController.AutonomyTier.SemiAutonomous,
            address(usdg),
            1e6,
            10e6,
            1e6,
            none,
            false
        );
    }

    function test_index_lists_an_owners_agents_in_order() public {
        uint256 a = _create(gwen, "research");
        uint256 b = _create(gwen, "billing");

        assertEq(agents.agentCountOf(gwen), 2);
        uint256[] memory ids = agents.agentIdsOf(gwen);
        assertEq(ids.length, 2);
        assertEq(ids[0], a);
        assertEq(ids[1], b);
    }

    function test_index_is_scoped_per_owner() public {
        _create(gwen, "research");
        uint256 f = _create(felix, "shopping");

        assertEq(agents.agentCountOf(felix), 1);
        assertEq(agents.agentIdsOf(felix)[0], f);
        assertEq(agents.agentCountOf(makeAddr("nobody")), 0);
    }

    function test_revoked_agent_stays_listed() public {
        uint256 a = _create(gwen, "research");
        vm.prank(gwen);
        agents.revokeAgent(a);

        assertEq(agents.agentCountOf(gwen), 1);
        assertEq(uint8(agents.getAgent(a).status), uint8(AgentController.AgentStatus.Revoked));
    }

    function test_owner_can_rename_an_agent() public {
        uint256 a = _create(gwen, "research");

        vm.prank(gwen);
        agents.renameAgent(a, "research-v2");
        assertEq(agents.getAgent(a).label, "research-v2");

        // Everything else about the agent is where it was.
        assertEq(agents.getAgent(a).agentSigner, signer);
        assertEq(agents.getAgent(a).ownerProfile, gwen);
    }

    function test_rename_is_owner_only_and_validated() public {
        uint256 a = _create(gwen, "research");

        vm.expectRevert(UnauthorizedAgentOwner.selector);
        vm.prank(felix);
        agents.renameAgent(a, "mine-now");

        vm.expectRevert(InvalidLabelLength.selector);
        vm.prank(gwen);
        agents.renameAgent(a, "");

        vm.prank(gwen);
        agents.revokeAgent(a);
        vm.expectRevert(AgentAlreadyRevoked.selector);
        vm.prank(gwen);
        agents.renameAgent(a, "retired");
    }
}
