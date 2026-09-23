// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../src/ProtocolAuthority.sol";
import {AccountRegistry} from "../src/AccountRegistry.sol";
import {RequestLedger} from "../src/RequestLedger.sol";
import {IProtocolAuthority} from "../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../src/interfaces/IAccountRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract RequestLedgerReceiptTest is Test {
    ProtocolAuthority protocol;
    AccountRegistry registry;
    RequestLedger requests;
    MockERC20 usdg;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address felix = makeAddr("felix");

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        protocol = new ProtocolAuthority(compliance);
        registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        requests = new RequestLedger(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
        usdg.mint(felix, 100e6);
        vm.prank(felix);
        usdg.approve(address(requests), type(uint256).max);
    }

    function test_open_request_has_no_payer_yet() public {
        vm.prank(gwen);
        uint256 id = requests.create(
            gwen,
            address(usdg),
            false,
            25e6,
            bytes32(0),
            bytes32(0),
            uint64(block.timestamp + 1 hours)
        );

        RequestLedger.Request memory r = requests.getRequest(id);
        assertEq(r.payer, address(0));
        assertEq(r.fulfilledAt, 0);
    }

    function test_fulfilment_records_payer_and_time() public {
        vm.prank(gwen);
        uint256 id = requests.create(
            gwen,
            address(usdg),
            false,
            25e6,
            bytes32(0),
            bytes32(0),
            uint64(block.timestamp + 1 hours)
        );

        vm.warp(block.timestamp + 10 minutes);
        vm.prank(felix);
        requests.fulfill(id, 25e6, bytes32(0));

        RequestLedger.Request memory r = requests.getRequest(id);
        assertEq(uint8(r.status), uint8(RequestLedger.RequestStatus.Fulfilled));
        assertEq(r.payer, felix);
        assertEq(r.fulfilledAt, uint64(block.timestamp));
    }

    function test_cancelled_request_records_nothing() public {
        vm.startPrank(gwen);
        uint256 id = requests.create(
            gwen,
            address(usdg),
            false,
            25e6,
            bytes32(0),
            bytes32(0),
            uint64(block.timestamp + 1 hours)
        );
        requests.cancel(id);
        vm.stopPrank();

        RequestLedger.Request memory r = requests.getRequest(id);
        assertEq(r.payer, address(0));
        assertEq(r.fulfilledAt, 0);
    }
}
