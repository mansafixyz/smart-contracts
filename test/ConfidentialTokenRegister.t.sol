// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AltBn128} from "../src/confidential/AltBn128.sol";
import {ConfidentialToken} from "../src/confidential/ConfidentialToken.sol";
import {StubTransferVerifier} from "../src/confidential/StubTransferVerifier.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import "../src/libraries/ProtocolErrors.sol";

contract ConfidentialTokenRegisterTest is Test {
    ConfidentialToken confidential;

    address admin = makeAddr("admin");
    address felix = makeAddr("felix");

    function setUp() public {
        MockERC20 usdg = new MockERC20("Global Dollar", "USDG", 6);
        confidential =
            new ConfidentialToken(IERC20(address(usdg)), new StubTransferVerifier(), admin);
    }

    function test_accepts_a_real_curve_point() public {
        // The generator, which is the least complicated point satisfying y^2 = x^3 + 3.
        vm.prank(felix);
        confidential.register(1, 2);
        assertTrue(confidential.registered(felix));

        (uint256 x, uint256 y) = confidential.publicKeyOf(felix);
        assertEq(x, 1);
        assertEq(y, 2);
    }

    function test_accepts_a_derived_public_key() public {
        // Derived exactly as a client would derive one: a secret scalar against G.
        AltBn128.Point memory p = AltBn128.encode(0xdeadbeef);
        vm.prank(felix);
        confidential.register(p.x, p.y);
        assertTrue(confidential.registered(felix));
    }

    function test_rejects_a_point_off_the_curve() public {
        // Those placeholder pairs from the earliest tests miss the curve entirely,
        // and such a key would lock the account out of everything credited to it.
        vm.expectRevert(InvalidPublicKey.selector);
        vm.prank(felix);
        confidential.register(7, 11);
    }

    function test_rejects_the_identity() public {
        vm.expectRevert(InvalidPublicKey.selector);
        vm.prank(felix);
        confidential.register(0, 0);
    }

    function test_rejects_coordinates_outside_the_field() public {
        // (x, y + p) still solves the equation mod p, yet is not reduced.
        uint256 p = AltBn128.FIELD_MODULUS;
        vm.expectRevert(InvalidPublicKey.selector);
        vm.prank(felix);
        confidential.register(1, 2 + p);
    }

    function test_valid_key_still_registers_only_once() public {
        vm.startPrank(felix);
        confidential.register(1, 2);
        vm.expectRevert(AccountAlreadyRegistered.selector);
        confidential.register(1, 2);
        vm.stopPrank();
    }
}
