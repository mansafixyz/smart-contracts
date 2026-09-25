// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../src/ProtocolAuthority.sol";
import {AccountRegistry} from "../src/AccountRegistry.sol";
import {IProtocolAuthority} from "../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../src/interfaces/IAccountRegistry.sol";
import "../src/libraries/ProtocolErrors.sol";

contract HandleChangeTest is Test {
    ProtocolAuthority protocol;
    AccountRegistry registry;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address felix = makeAddr("felix");

    function setUp() public {
        protocol = new ProtocolAuthority(compliance);
        registry = new AccountRegistry(IProtocolAuthority(address(protocol)));

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
        vm.prank(felix);
        registry.createProfile("felix", AccountRegistry.AccountKind.Personal);
    }

    function test_change_moves_the_profile_and_frees_the_old_handle() public {
        vm.prank(gwen);
        registry.changeHandle("gwenith");

        // The record answers to the new name, and to that name alone.
        assertEq(registry.resolveHandle("gwenith"), gwen);
        assertEq(registry.resolveHandle("gwen"), address(0));
        assertEq(registry.handleOf(gwen), "gwenith");
        assertEq(registry.fullHandle(gwen), "gwenith.mansafi");

        // Whatever was given up is available to anyone now.
        address newcomer = makeAddr("newcomer");
        vm.prank(newcomer);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
        assertEq(registry.resolveHandle("gwen"), newcomer);
    }

    function test_change_keeps_the_rest_of_the_profile() public {
        vm.prank(compliance);
        registry.setKycTier(gwen, IAccountRegistry.KycTier.Enhanced);
        uint64 createdAt = registry.profileOf(gwen).createdAt;

        vm.warp(block.timestamp + 1 days);
        vm.prank(gwen);
        registry.changeHandle("gwenith");

        AccountRegistry.Profile memory p = registry.profileOf(gwen);
        assertEq(uint8(p.kycTier), uint8(IAccountRegistry.KycTier.Enhanced));
        assertEq(p.createdAt, createdAt);
        assertEq(p.updatedAt, uint64(block.timestamp));
    }

    function test_cannot_take_a_handle_someone_else_holds() public {
        vm.expectRevert(HandleAlreadyTaken.selector);
        vm.prank(gwen);
        registry.changeHandle("felix");
    }

    function test_cannot_rename_onto_your_own_current_handle() public {
        vm.expectRevert(HandleAlreadyTaken.selector);
        vm.prank(gwen);
        registry.changeHandle("gwen");
    }

    function test_new_handle_is_validated_like_a_fresh_one() public {
        vm.startPrank(gwen);
        vm.expectRevert(InvalidHandleCharacters.selector);
        registry.changeHandle("Gwen");

        vm.expectRevert(InvalidHandleLength.selector);
        registry.changeHandle("");
        vm.stopPrank();
    }

    function test_requires_a_profile() public {
        vm.expectRevert(ProfileNotFound.selector);
        vm.prank(makeAddr("stranger"));
        registry.changeHandle("stranger");
    }

    function test_handle_availability_matches_the_claim_rules() public view {
        assertTrue(registry.handleAvailable("newcomer"));
        assertFalse(registry.handleAvailable("gwen")); // taken
        assertFalse(registry.handleAvailable("Gwen")); // uppercase
        assertFalse(registry.handleAvailable("gwen.mansafi")); // suffix is not part of it
        assertFalse(registry.handleAvailable("")); // empty
        assertFalse(registry.handleAvailable("abcdefghijklmnopqrstuvwxyz0123456")); // 33 chars
    }

    function test_profile_by_handle_returns_the_record_or_nothing() public view {
        AccountRegistry.Profile memory p = registry.profileByHandle("gwen");
        assertTrue(p.exists);
        assertEq(p.owner, gwen);
        assertEq(p.handle, "gwen");

        AccountRegistry.Profile memory none = registry.profileByHandle("nobody");
        assertFalse(none.exists);
        assertEq(none.owner, address(0));
    }
}
