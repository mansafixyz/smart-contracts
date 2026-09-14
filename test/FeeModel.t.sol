// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../src/ProtocolAuthority.sol";
import {AccountRegistry} from "../src/AccountRegistry.sol";
import {AgentController} from "../src/AgentController.sol";
import {RequestLedger} from "../src/RequestLedger.sol";
import {StakingVault} from "../src/fees/StakingVault.sol";
import {FeeSchedule} from "../src/fees/FeeSchedule.sol";
import {IProtocolAuthority} from "../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../src/interfaces/IAccountRegistry.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Drives the whole $MANSA fee model from one end to the other: the
///         arithmetic behind a quote, the curve that rewards holding and
///         staking, and the routing of fees through both settlement paths.
contract FeeModelTest is Test {
    ProtocolAuthority protocol;
    AccountRegistry registry;
    AgentController agents;
    RequestLedger requests;
    StakingVault staking;
    FeeSchedule fees;
    MockERC20 usdg; // 6 dp settlement token
    MockERC20 mansafi; // 18 dp governance token

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address treasury = makeAddr("treasury");
    address gwen = makeAddr("gwen");
    address felix = makeAddr("felix");
    address vendor = makeAddr("vendor");
    address signer = makeAddr("signer");

    function usd(uint256 d) internal pure returns (uint256) {
        return d * 1e6;
    }

    function mansa(uint256 d) internal pure returns (uint256) {
        return d * 1e18;
    }

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        mansafi = new MockERC20("MansaFi", "MANSAFI", 18);

        vm.prank(admin);
        protocol = new ProtocolAuthority(compliance);
        registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        agents = new AgentController(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );
        requests = new RequestLedger(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );

        staking = new StakingVault(IERC20(address(mansafi)));
        fees = new FeeSchedule(admin, IERC20(address(mansafi)), staking);

        vm.prank(admin);
        protocol.setFeeConfig(treasury, address(fees));

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
        vm.prank(felix);
        registry.createProfile("felix", AccountRegistry.AccountKind.Personal);

        usdg.mint(gwen, usd(1_000_000));
        usdg.mint(felix, usd(1_000_000));
    }

    // ── Quoting and the discount curve ─────────────────────────────────────────

    function test_base_fee_no_mansafi() public view {
        // A tenth of a percent on 1,000 USDG is 1 USDG, with nothing taken off.
        (uint256 fee, uint256 bps) = fees.quoteFee(gwen, usd(1_000));
        assertEq(fee, usd(1));
        assertEq(bps, 10);
        assertEq(fees.discountBpsOf(gwen), 0);
    }

    function test_holding_earns_partial_discount() public {
        // Holding is halved: 20k in the wallet is 10k of weight, landing on 25%.
        mansafi.mint(gwen, mansa(20_000));
        assertEq(fees.loyaltyWeightOf(gwen), mansa(10_000));
        assertEq(fees.discountBpsOf(gwen), 2_500);

        (uint256 fee,) = fees.quoteFee(gwen, usd(1_000));
        assertEq(fee, usd(1) * 7_500 / 10_000); // 25% off => 0.75 USDG
    }

    function test_staking_beats_holding() public {
        // Staking is not: 100k locked up is 100k of weight, landing on 50%.
        mansafi.mint(gwen, mansa(100_000));
        vm.startPrank(gwen);
        mansafi.approve(address(staking), type(uint256).max);
        staking.stake(mansa(100_000));
        vm.stopPrank();

        assertEq(fees.loyaltyWeightOf(gwen), mansa(100_000));
        assertEq(fees.discountBpsOf(gwen), 5_000);

        (uint256 fee,) = fees.quoteFee(gwen, usd(1_000));
        assertEq(fee, usd(1) / 2); // 50% off
    }

    function test_top_tier_discount() public {
        mansafi.mint(gwen, mansa(1_000_000));
        vm.startPrank(gwen);
        mansafi.approve(address(staking), type(uint256).max);
        staking.stake(mansa(1_000_000));
        vm.stopPrank();
        assertEq(fees.discountBpsOf(gwen), 7_500); // 75% off, the deepest tier
    }

    function test_fee_cap_applies() public view {
        // A tenth of a percent on 100,000 USDG would be 100 USDG. The cap says 5.
        (uint256 fee,) = fees.quoteFee(gwen, usd(100_000));
        assertEq(fee, usd(5));
    }

    function test_unstake_lowers_discount() public {
        mansafi.mint(gwen, mansa(100_000));
        vm.startPrank(gwen);
        mansafi.approve(address(staking), type(uint256).max);

        // While staked: 100k of weight, so the 50% rung.
        staking.stake(mansa(100_000));
        assertEq(fees.discountBpsOf(gwen), 5_000);

        // Once withdrawn those tokens sit in the wallet at half weight, which drops
        // the account to the 25% rung. Staking is worth more than holding.
        staking.unstake(mansa(100_000));
        vm.stopPrank();
        assertEq(fees.loyaltyWeightOf(gwen), mansa(50_000));
        assertEq(fees.discountBpsOf(gwen), 2_500);

        // Send the tokens elsewhere and there is no discount left at all.
        vm.prank(gwen);
        mansafi.transfer(vendor, mansa(100_000));
        assertEq(fees.discountBpsOf(gwen), 0);
    }

    // ── Fee routing through settlement ─────────────────────────────────────────

    function _fundedAgent() internal returns (uint256 agentId) {
        address[] memory none = new address[](0);
        vm.prank(gwen);
        agentId = agents.createAgent(
            signer,
            "bot",
            AgentController.AutonomyTier.SemiAutonomous,
            address(usdg),
            usd(2_000),
            usd(10_000),
            usd(2_000),
            none,
            false
        );
        vm.startPrank(gwen);
        usdg.approve(address(agents), type(uint256).max);
        agents.fundAgent(agentId, usd(5_000));
        vm.stopPrank();
    }

    function test_agent_pay_charges_fee_to_treasury() public {
        // gwen locks up 10k $MANSA, which is worth 25% off.
        mansafi.mint(gwen, mansa(10_000));
        vm.startPrank(gwen);
        mansafi.approve(address(staking), type(uint256).max);
        staking.stake(mansa(10_000));
        vm.stopPrank();

        uint256 agentId = _fundedAgent();

        // On 1,000 USDG: 1 USDG before the discount, 0.75 USDG after it.
        vm.prank(signer);
        agents.payInvoice(agentId, vendor, usd(1_000), bytes32("inv"));

        uint256 expectedFee = usd(1) * 7_500 / 10_000;
        assertEq(usdg.balanceOf(vendor), usd(1_000)); // recipient kept whole
        assertEq(usdg.balanceOf(treasury), expectedFee); // fee to treasury
        assertEq(agents.vaultBalance(agentId), usd(5_000) - usd(1_000) - expectedFee);
    }

    function test_agent_pay_no_fee_when_unconfigured() public {
        // Unwire the routing and settlement is an ordinary transfer once more.
        vm.prank(admin);
        protocol.setFeeConfig(address(0), address(0));

        uint256 agentId = _fundedAgent();
        vm.prank(signer);
        agents.payInvoice(agentId, vendor, usd(1_000), bytes32("inv"));

        assertEq(usdg.balanceOf(vendor), usd(1_000));
        assertEq(usdg.balanceOf(treasury), 0);
        assertEq(agents.vaultBalance(agentId), usd(5_000) - usd(1_000));
    }

    function test_payment_request_charges_fee_on_top() public {
        // gwen asks for 500 USDG; felix, holding no $MANSA, covers it and the fee.
        vm.prank(gwen);
        uint256 id = requests.create(
            gwen,
            address(usdg),
            false,
            usd(500),
            bytes32(0),
            bytes32(0),
            uint64(block.timestamp + 1 days)
        );

        uint256 gwenBefore = usdg.balanceOf(gwen);
        uint256 felixBefore = usdg.balanceOf(felix);

        vm.startPrank(felix);
        usdg.approve(address(requests), type(uint256).max);
        requests.fulfill(id, usd(500), bytes32(0));
        vm.stopPrank();

        uint256 fee = usd(500) * 10 / 10_000; // 0.10% = 0.5 USDG, no discount
        assertEq(usdg.balanceOf(gwen), gwenBefore + usd(500)); // requester whole
        assertEq(usdg.balanceOf(treasury), fee);
        assertEq(usdg.balanceOf(felix), felixBefore - usd(500) - fee); // payer pays fee
    }

    function test_only_authority_tunes_schedule() public {
        vm.expectRevert();
        vm.prank(gwen);
        fees.setSchedule(20, usd(10), 5_000);

        vm.prank(admin);
        fees.setSchedule(20, usd(10), 5_000);
        assertEq(fees.baseFeeBps(), 20);
    }
}
