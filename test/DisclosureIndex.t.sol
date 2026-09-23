// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccountRegistry} from "../src/AccountRegistry.sol";
import {DisclosureLog} from "../src/DisclosureLog.sol";
import {ProtocolAuthority} from "../src/ProtocolAuthority.sol";
import {IProtocolAuthority} from "../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../src/interfaces/IAccountRegistry.sol";
import "../src/libraries/ProtocolErrors.sol";

contract DisclosureIndexTest is Test {
    ProtocolAuthority protocol;
    AccountRegistry registry;
    DisclosureLog disclosures;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address felix = makeAddr("felix");

    function setUp() public {
        protocol = new ProtocolAuthority(compliance);
        registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        disclosures = new DisclosureLog(IAccountRegistry(address(registry)));

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
        vm.prank(felix);
        registry.createProfile("felix", AccountRegistry.AccountKind.Personal);
    }

    function test_index_tracks_a_profiles_receipts_in_order() public {
        vm.startPrank(gwen);
        uint256 a = disclosures.file("tx-a", keccak256("auditor"), keccak256("proof-a"));
        uint256 b = disclosures.file("tx-b", keccak256("auditor"), keccak256("proof-b"));
        vm.stopPrank();

        assertEq(disclosures.receiptCountOf(gwen), 2);
        uint256[] memory ids = disclosures.receiptIdsOf(gwen);
        assertEq(ids.length, 2);
        assertEq(ids[0], a);
        assertEq(ids[1], b);
    }

    function test_index_is_scoped_per_profile() public {
        vm.prank(gwen);
        disclosures.file("tx-gwen", keccak256("auditor"), keccak256("proof"));
        vm.prank(felix);
        disclosures.file("tx-felix", keccak256("auditor"), keccak256("proof"));

        assertEq(disclosures.receiptCountOf(gwen), 1);
        assertEq(disclosures.receiptCountOf(felix), 1);
        assertEq(disclosures.receiptIdsOf(gwen)[0], 1);
        assertEq(disclosures.receiptIdsOf(felix)[0], 2);
    }

    function test_index_empty_for_unknown_profile() public view {
        assertEq(disclosures.receiptCountOf(address(0xdead)), 0);
        assertEq(disclosures.receiptIdsOf(address(0xdead)).length, 0);
    }

    function test_paged_index_walks_the_full_list() public {
        uint256[] memory filed = new uint256[](3);
        vm.startPrank(gwen);
        filed[0] = disclosures.file("tx-a", keccak256("auditor"), keccak256("proof-a"));
        filed[1] = disclosures.file("tx-b", keccak256("auditor"), keccak256("proof-b"));
        filed[2] = disclosures.file("tx-c", keccak256("auditor"), keccak256("proof-c"));
        vm.stopPrank();

        // One complete page, then the remainder, ordered as filed.
        uint256[] memory page = disclosures.receiptIdsOf(gwen, 0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], filed[0]);
        assertEq(page[1], filed[1]);

        page = disclosures.receiptIdsOf(gwen, 2, 2);
        assertEq(page.length, 1);
        assertEq(page[0], filed[2]);
    }

    function test_paged_index_is_empty_past_the_end() public {
        vm.prank(gwen);
        disclosures.file("tx-a", keccak256("auditor"), keccak256("proof-a"));

        assertEq(disclosures.receiptIdsOf(gwen, 1, 10).length, 0);
        assertEq(disclosures.receiptIdsOf(felix, 0, 10).length, 0);
    }

    function test_transfer_index_collects_every_disclosure_of_one_transfer() public {
        vm.prank(gwen);
        uint256 toAuditor = disclosures.file("tx-shared", keccak256("auditor"), keccak256("p1"));
        vm.prank(felix);
        uint256 toBank = disclosures.file("tx-shared", keccak256("bank"), keccak256("p2"));
        vm.prank(gwen);
        disclosures.file("tx-other", keccak256("auditor"), keccak256("p3"));

        uint256[] memory ids = disclosures.receiptIdsForTransfer("tx-shared");
        assertEq(ids.length, 2);
        assertEq(ids[0], toAuditor);
        assertEq(ids[1], toBank);
    }

    function test_transfer_index_is_empty_for_an_undisclosed_transfer() public view {
        assertEq(disclosures.receiptIdsForTransfer("never-disclosed").length, 0);
    }
}
