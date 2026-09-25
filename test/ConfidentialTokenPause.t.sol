// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AltBn128} from "../src/confidential/AltBn128.sol";
import {ConfidentialToken} from "../src/confidential/ConfidentialToken.sol";
import {StubTransferVerifier} from "../src/confidential/StubTransferVerifier.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import "../src/libraries/ProtocolErrors.sol";

contract ConfidentialTokenPauseTest is Test {
    ConfidentialToken confidential;
    MockERC20 usdg;

    address admin = makeAddr("admin");
    address felix = makeAddr("felix");
    address gwen = makeAddr("gwen");

    uint256 constant USDG_ONE = 1e6;

    function usd(uint256 dollars) internal pure returns (uint256) {
        return dollars * USDG_ONE;
    }

    /// A reproducible, genuine ElGamal public key, being the point `k * G`.
    function pk(uint256 k) internal view returns (uint256 x, uint256 y) {
        AltBn128.Point memory p = AltBn128.encode(k);
        return (p.x, p.y);
    }

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        confidential =
            new ConfidentialToken(IERC20(address(usdg)), new StubTransferVerifier(), admin);

        usdg.mint(felix, usd(1_000));

        (uint256 fx, uint256 fy) = pk(2);
        (uint256 gx, uint256 gy) = pk(3);

        vm.startPrank(felix);
        confidential.register(fx, fy);
        usdg.approve(address(confidential), type(uint256).max);
        confidential.deposit(usd(100));
        vm.stopPrank();

        vm.prank(gwen);
        confidential.register(gx, gy);
    }

    function test_only_authority_can_pause() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(felix);
        confidential.setPaused(true);

        vm.prank(admin);
        confidential.setPaused(true);
        assertTrue(confidential.paused());
    }

    function test_pause_blocks_deposit_withdraw_transfer() public {
        vm.prank(admin);
        confidential.setPaused(true);

        uint256[] memory signals = new uint256[](0);
        ConfidentialToken.Ciphertext memory delta = confidential.encryptedBalanceOf(gwen);

        vm.startPrank(felix);
        vm.expectRevert(ConfidentialToken.TokenPaused.selector);
        confidential.deposit(usd(10));

        vm.expectRevert(ConfidentialToken.TokenPaused.selector);
        confidential.withdraw(usd(10), "", signals);

        vm.expectRevert(ConfidentialToken.TokenPaused.selector);
        confidential.confidentialTransfer(gwen, delta, delta, "", signals);
        vm.stopPrank();
    }

    function test_registration_and_verifier_rotation_work_while_paused() public {
        vm.prank(admin);
        confidential.setPaused(true);

        // Registration stays open even while the layer is frozen.
        address newcomer = makeAddr("newcomer");
        (uint256 nx, uint256 ny) = pk(5);
        vm.prank(newcomer);
        confidential.register(nx, ny);
        assertTrue(confidential.registered(newcomer));

        // And the verifier can still be swapped, which is how recovery happens.
        StubTransferVerifier next = new StubTransferVerifier();
        vm.prank(admin);
        confidential.setVerifier(next);
    }

    function test_unpause_restores_value_movement() public {
        vm.prank(admin);
        confidential.setPaused(true);
        vm.prank(admin);
        confidential.setPaused(false);

        vm.prank(felix);
        confidential.deposit(usd(10));
        assertEq(confidential.totalWrapped(), usd(110));
    }

    function test_withdraw_beyond_the_pool_is_refused_by_name() public {
        uint256[] memory signals = new uint256[](0);
        // The stub verifier waves everything through; the pool is the last line.
        vm.expectRevert(ExceedsWrappedSupply.selector);
        vm.prank(felix);
        confidential.withdraw(usd(101), "", signals);
    }
}
