// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../src/ProtocolAuthority.sol";
import {AccountRegistry} from "../src/AccountRegistry.sol";
import {RequestLedger} from "../src/RequestLedger.sol";
import {IProtocolAuthority} from "../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../src/interfaces/IAccountRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import "../src/libraries/ProtocolErrors.sol";

contract RequestLedgerIndexTest is Test {
    ProtocolAuthority protocol;
    AccountRegistry registry;
    RequestLedger requests;
    MockERC20 usdg;

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address felix = makeAddr("felix");

    uint256 constant USDG_ONE = 1e6;

    function usd(uint256 dollars) internal pure returns (uint256) {
        return dollars * USDG_ONE;
    }

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);

        vm.prank(admin);
        protocol = new ProtocolAuthority(compliance);
        registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        requests = new RequestLedger(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
        vm.prank(felix);
        registry.createProfile("felix", AccountRegistry.AccountKind.Personal);
        usdg.mint(felix, usd(1_000));
    }

    function _create(address who, uint256 amount) internal returns (uint256 id) {
        vm.prank(who);
        id = requests.create(
            who,
            address(usdg),
            false,
            amount,
            bytes32(0),
            bytes32(0),
            uint64(block.timestamp + 1 hours)
        );
    }

    function test_index_lists_a_requesters_requests() public {
        uint256 a = _create(gwen, usd(10));
        uint256 b = _create(gwen, usd(20));

        assertEq(requests.requestCountOf(gwen), 2);
        uint256[] memory ids = requests.requestIdsOf(gwen);
        assertEq(ids[0], a);
        assertEq(ids[1], b);
        assertEq(requests.requestCountOf(felix), 0);
    }

    function test_is_fulfillable_lifecycle() public {
        uint256 id = _create(gwen, usd(25));
        assertTrue(requests.isFulfillable(id));

        // Settlement closes it.
        vm.startPrank(felix);
        usdg.approve(address(requests), type(uint256).max);
        requests.fulfill(id, usd(25), bytes32(0));
        vm.stopPrank();
        assertFalse(requests.isFulfillable(id));
    }

    function test_is_fulfillable_false_after_cancel() public {
        uint256 id = _create(gwen, usd(25));
        vm.prank(gwen);
        requests.cancel(id);
        assertFalse(requests.isFulfillable(id));
    }

    function test_is_fulfillable_false_after_expiry() public {
        uint256 id = _create(gwen, usd(25));
        vm.warp(block.timestamp + 2 hours);
        assertFalse(requests.isFulfillable(id));
    }

    function test_is_fulfillable_false_for_unknown_id() public view {
        assertFalse(requests.isFulfillable(999));
    }

    function test_paged_index_walks_the_full_list() public {
        uint256[] memory created = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            created[i] = _create(gwen, usd(10 + i));
        }

        // Two whole pages and a remainder, in the order they were raised.
        uint256[] memory page = requests.requestIdsOf(gwen, 0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], created[0]);
        assertEq(page[1], created[1]);

        page = requests.requestIdsOf(gwen, 2, 2);
        assertEq(page.length, 2);
        assertEq(page[0], created[2]);
        assertEq(page[1], created[3]);

        page = requests.requestIdsOf(gwen, 4, 2);
        assertEq(page.length, 1);
        assertEq(page[0], created[4]);
    }

    function test_paged_index_is_empty_past_the_end() public {
        _create(gwen, usd(10));
        assertEq(requests.requestIdsOf(gwen, 1, 10).length, 0);
        assertEq(requests.requestIdsOf(felix, 0, 10).length, 0);
    }
}
