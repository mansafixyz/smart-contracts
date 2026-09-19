// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../src/ProtocolAuthority.sol";
import {AccountRegistry} from "../src/AccountRegistry.sol";
import {AgentController} from "../src/AgentController.sol";
import {RequestLedger} from "../src/RequestLedger.sol";
import {DisclosureLog} from "../src/DisclosureLog.sol";
import {AltBn128} from "../src/confidential/AltBn128.sol";
import {ConfidentialToken} from "../src/confidential/ConfidentialToken.sol";
import {StubTransferVerifier} from "../src/confidential/StubTransferVerifier.sol";
import {IProtocolAuthority} from "../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../src/interfaces/IAccountRegistry.sol";
import {IConfidentialTransferVerifier} from "../src/confidential/IConfidentialTransferVerifier.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import "../src/libraries/ProtocolErrors.sol";

contract MansaFiTest is Test {
    ProtocolAuthority protocol;
    AccountRegistry registry;
    AgentController agents;
    RequestLedger requests;
    DisclosureLog disclosures;
    ConfidentialToken confidential;
    MockERC20 usdg;

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen"); // human profile, owns an agent
    address felix = makeAddr("felix"); // pays gwen's requests
    address vendor = makeAddr("vendor"); // agent pays this recipient
    address agentSigner = makeAddr("agentSigner");

    uint256 constant USDG_ONE = 1e6; // USDG has 6 decimals

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

        vm.prank(admin);
        protocol = new ProtocolAuthority(compliance);

        registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        agents = new AgentController(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );
        requests = new RequestLedger(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );
        disclosures = new DisclosureLog(IAccountRegistry(address(registry)));
        confidential =
            new ConfidentialToken(IERC20(address(usdg)), new StubTransferVerifier(), admin);

        // Account records.
        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
        vm.prank(felix);
        registry.createProfile("felix", AccountRegistry.AccountKind.Personal);

        usdg.mint(gwen, usd(1_000));
        usdg.mint(felix, usd(1_000));
    }

    // ── Protocol protocol ──────────────────────────────────────────────────────

    function test_config_initialised() public view {
        assertEq(protocol.authority(), admin);
        assertEq(protocol.complianceAuthority(), compliance);
        assertFalse(protocol.paused());
    }

    function test_only_authority_can_pause() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(gwen);
        protocol.setPause(true);

        vm.prank(admin);
        protocol.setPause(true);
        assertTrue(protocol.paused());
    }

    // ── Registry ───────────────────────────────────────────────────────────────

    function test_handle_resolution_and_suffix() public view {
        assertEq(registry.resolveHandle("gwen"), gwen);
        assertEq(registry.fullHandle(gwen), "gwen.mansafi");
        assertTrue(registry.isRegistered(gwen));
    }

    function test_duplicate_handle_rejected() public {
        vm.expectRevert(HandleAlreadyTaken.selector);
        vm.prank(vendor);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
    }

    function test_invalid_handle_characters_rejected() public {
        vm.expectRevert(InvalidHandleCharacters.selector);
        vm.prank(vendor);
        registry.createProfile("Gwen", AccountRegistry.AccountKind.Personal);
    }

    function test_one_profile_per_wallet() public {
        vm.expectRevert(ProfileAlreadyExists.selector);
        vm.prank(gwen);
        registry.createProfile("gwen2", AccountRegistry.AccountKind.Personal);
    }

    function test_only_compliance_sets_kyc() public {
        vm.expectRevert(UnauthorizedComplianceAuthority.selector);
        vm.prank(admin);
        registry.setKycTier(gwen, IAccountRegistry.KycTier.Basic);

        vm.prank(compliance);
        registry.setKycTier(gwen, IAccountRegistry.KycTier.Enhanced);
        assertEq(uint256(registry.kycTierOf(gwen)), uint256(IAccountRegistry.KycTier.Enhanced));
    }

    // ── Agents ─────────────────────────────────────────────────────────────────

    function _createAgent() internal returns (uint256 agentId) {
        address[] memory none = new address[](0);
        vm.prank(gwen);
        agentId = agents.createAgent(
            agentSigner,
            "coding-assistant",
            AgentController.AutonomyTier.SemiAutonomous,
            address(usdg),
            usd(10), // perTxLimit
            usd(50), // dailyLimit
            usd(5), // hitlThreshold
            none,
            false
        );

        vm.startPrank(gwen);
        usdg.approve(address(agents), type(uint256).max);
        agents.fundAgent(agentId, usd(100));
        vm.stopPrank();
    }

    function test_create_and_fund_agent() public {
        uint256 agentId = _createAgent();
        assertEq(agents.vaultBalance(agentId), usd(100));
        AgentController.Agent memory a = agents.getAgent(agentId);
        assertEq(a.ownerProfile, gwen);
        assertEq(a.agentSigner, agentSigner);
    }

    function test_agent_requires_profile() public {
        address[] memory none = new address[](0);
        vm.expectRevert(ProfileNotFound.selector);
        vm.prank(vendor);
        agents.createAgent(
            agentSigner,
            "x",
            AgentController.AutonomyTier.SemiAutonomous,
            address(usdg),
            usd(10),
            usd(50),
            usd(5),
            none,
            false
        );
    }

    function test_pay_within_threshold_settles() public {
        uint256 agentId = _createAgent();

        vm.prank(agentSigner);
        agents.payInvoice(agentId, vendor, usd(4), bytes32("x402-inv-1"));

        assertEq(usdg.balanceOf(vendor), usd(4));
        assertEq(agents.vaultBalance(agentId), usd(96));
    }

    function test_pay_above_threshold_reverts() public {
        uint256 agentId = _createAgent();
        vm.expectRevert(AmountExceedsHitlThreshold.selector);
        vm.prank(agentSigner);
        agents.payInvoice(agentId, vendor, usd(6), bytes32(0));
    }

    function test_pay_over_per_tx_limit_reverts() public {
        uint256 agentId = _createAgent();
        vm.expectRevert(PerTransactionLimitExceeded.selector);
        vm.prank(agentSigner);
        agents.payInvoice(agentId, vendor, usd(11), bytes32(0));
    }

    function test_only_signer_can_pay() public {
        uint256 agentId = _createAgent();
        vm.expectRevert(UnauthorizedAgentSigner.selector);
        vm.prank(gwen);
        agents.payInvoice(agentId, vendor, usd(4), bytes32(0));
    }

    function test_daily_limit_enforced_and_rolls() public {
        uint256 agentId = _createAgent();

        // Lift the per-payment ceiling to 50, leaving the daily one to do the work.
        address[] memory none = new address[](0);
        vm.prank(gwen);
        agents.updateSpendPolicy(agentId, usd(50), usd(50), usd(50), false, none);

        vm.startPrank(agentSigner);
        agents.payInvoice(agentId, vendor, usd(50), bytes32(0));
        vm.expectRevert(DailyLimitExceeded.selector);
        agents.payInvoice(agentId, vendor, usd(1), bytes32(0));
        vm.stopPrank();

        // Once the window turns over, the agent can spend again.
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(agentSigner);
        agents.payInvoice(agentId, vendor, usd(50), bytes32(0));
        assertEq(usdg.balanceOf(vendor), usd(100));
    }

    function test_queue_approve_flow() public {
        uint256 agentId = _createAgent();

        vm.prank(agentSigner);
        uint256 pendingId =
            agents.queueInvoice(agentId, vendor, usd(9), bytes32("x402-inv-2"), bytes32("memo"));

        // Still nothing has left the vault.
        assertEq(agents.vaultBalance(agentId), usd(100));

        vm.prank(gwen);
        agents.approvePending(agentId, pendingId);

        assertEq(usdg.balanceOf(vendor), usd(9));
        assertEq(agents.vaultBalance(agentId), usd(91));
    }

    function test_queue_reject_flow() public {
        uint256 agentId = _createAgent();

        vm.prank(agentSigner);
        uint256 pendingId =
            agents.queueInvoice(agentId, vendor, usd(9), bytes32(0), bytes32("memo"));

        vm.prank(gwen);
        agents.rejectPending(agentId, pendingId);

        assertEq(agents.vaultBalance(agentId), usd(100));
        AgentController.PendingApproval memory pa = agents.getPending(agentId, pendingId);
        assertFalse(pa.exists);
    }

    function test_queue_below_threshold_reverts() public {
        uint256 agentId = _createAgent();
        vm.expectRevert(AmountWithinHitlThreshold.selector);
        vm.prank(agentSigner);
        agents.queueInvoice(agentId, vendor, usd(4), bytes32(0), bytes32(0));
    }

    function test_allowlist_enforced() public {
        uint256 agentId = _createAgent();

        address[] memory allow = new address[](1);
        allow[0] = felix;
        vm.prank(gwen);
        agents.updateSpendPolicy(agentId, usd(10), usd(50), usd(5), true, allow);

        vm.expectRevert(RecipientNotAllowed.selector);
        vm.prank(agentSigner);
        agents.payInvoice(agentId, vendor, usd(4), bytes32(0));

        vm.prank(agentSigner);
        agents.payInvoice(agentId, felix, usd(4), bytes32(0));
        assertEq(usdg.balanceOf(felix), usd(1_000) + usd(4));
    }

    function test_pause_blocks_spend() public {
        uint256 agentId = _createAgent();
        vm.prank(admin);
        protocol.setPause(true);

        vm.expectRevert(ProtocolPaused.selector);
        vm.prank(agentSigner);
        agents.payInvoice(agentId, vendor, usd(4), bytes32(0));
    }

    function test_revoke_sweeps_vault() public {
        uint256 agentId = _createAgent();
        uint256 gwenBefore = usdg.balanceOf(gwen);

        vm.prank(gwen);
        agents.revokeAgent(agentId);

        assertEq(agents.vaultBalance(agentId), 0);
        assertEq(usdg.balanceOf(gwen), gwenBefore + usd(100));

        // Revocation ends spending for good.
        vm.expectRevert(AgentNotActive.selector);
        vm.prank(agentSigner);
        agents.payInvoice(agentId, vendor, usd(1), bytes32(0));
    }

    function test_paused_agent_cannot_spend_but_owner_can_revoke() public {
        uint256 agentId = _createAgent();

        vm.prank(gwen);
        agents.setAgentStatus(agentId, AgentController.AgentStatus.Paused);

        vm.expectRevert(AgentNotActive.selector);
        vm.prank(agentSigner);
        agents.payInvoice(agentId, vendor, usd(1), bytes32(0));

        // A paused agent can still be reconfigured, which is rather the point.
        vm.prank(gwen);
        agents.revokeAgent(agentId);
        assertEq(usdg.balanceOf(gwen), usd(900) + usd(100));
    }

    // ── Payment requests ─────────────────────────────────────────────────────

    function test_plain_payment_request() public {
        vm.prank(gwen);
        uint256 id = requests.create(
            gwen,
            address(usdg),
            false,
            usd(25),
            bytes32(0),
            bytes32(0),
            uint64(block.timestamp + 1 hours)
        );

        vm.startPrank(felix);
        usdg.approve(address(requests), type(uint256).max);
        requests.fulfill(id, usd(25), bytes32(0));
        vm.stopPrank();

        assertEq(usdg.balanceOf(gwen), usd(1_000) + usd(25));
        RequestLedger.Request memory r = requests.getRequest(id);
        assertEq(uint256(r.status), uint256(RequestLedger.RequestStatus.Fulfilled));
    }

    function test_plain_request_wrong_amount_reverts() public {
        vm.prank(gwen);
        uint256 id = requests.create(
            gwen,
            address(usdg),
            false,
            usd(25),
            bytes32(0),
            bytes32(0),
            uint64(block.timestamp + 1 hours)
        );
        vm.startPrank(felix);
        usdg.approve(address(requests), type(uint256).max);
        vm.expectRevert(RequestAmountMismatch.selector);
        requests.fulfill(id, usd(24), bytes32(0));
        vm.stopPrank();
    }

    function test_confidential_request_commitment() public {
        uint256 amount = usd(42);
        bytes32 blinding = keccak256("secret-blinding");
        bytes32 commitment = keccak256(abi.encodePacked(amount, blinding));

        vm.prank(gwen);
        uint256 id = requests.create(
            gwen,
            address(usdg),
            true,
            0,
            commitment,
            bytes32("memo"),
            uint64(block.timestamp + 1 hours)
        );

        // Hand a payer the wrong figure and the commitment refuses to match.
        vm.startPrank(felix);
        usdg.approve(address(requests), type(uint256).max);
        vm.expectRevert(RequestCommitmentMismatch.selector);
        requests.fulfill(id, usd(41), blinding);

        // The right figure with the right blinding goes through.
        requests.fulfill(id, amount, blinding);
        vm.stopPrank();

        assertEq(usdg.balanceOf(gwen), usd(1_000) + amount);
    }

    function test_request_cancel() public {
        vm.prank(gwen);
        uint256 id = requests.create(
            gwen,
            address(usdg),
            false,
            usd(25),
            bytes32(0),
            bytes32(0),
            uint64(block.timestamp + 1 hours)
        );
        vm.prank(gwen);
        requests.cancel(id);

        vm.startPrank(felix);
        usdg.approve(address(requests), type(uint256).max);
        vm.expectRevert(RequestNotOpen.selector);
        requests.fulfill(id, usd(25), bytes32(0));
        vm.stopPrank();
    }

    function test_request_expired_reverts() public {
        vm.prank(gwen);
        uint256 id = requests.create(
            gwen,
            address(usdg),
            false,
            usd(25),
            bytes32(0),
            bytes32(0),
            uint64(block.timestamp + 1 hours)
        );
        vm.warp(block.timestamp + 2 hours);
        vm.startPrank(felix);
        usdg.approve(address(requests), type(uint256).max);
        vm.expectRevert(RequestExpired.selector);
        requests.fulfill(id, usd(25), bytes32(0));
        vm.stopPrank();
    }

    // ── Disclosure ─────────────────────────────────────────────────────────────

    function test_file_disclosure() public {
        vm.prank(gwen);
        uint256 id = disclosures.file(
            "0xabc-tx-reference", keccak256("auditor"), keccak256("proof-payload")
        );
        DisclosureLog.DisclosureReceipt memory rec = disclosures.getReceipt(id);
        assertEq(rec.profile, gwen);
        assertEq(rec.viewerHash, keccak256("auditor"));
    }

    function test_disclosure_requires_profile() public {
        vm.expectRevert(ProfileNotFound.selector);
        vm.prank(vendor);
        disclosures.file("ref", bytes32(0), bytes32(0));
    }

    // ── Confidential token ─────────────────────────────────────────────────────

    function test_confidential_register_and_deposit() public {
        // Registers with a placeholder key that is nonetheless a true curve point;
        // in production the key is an ElGamal point a client derives from the
        // account's view key.
        (uint256 x, uint256 y) = pk(2);
        vm.startPrank(felix);
        confidential.register(x, y);
        usdg.approve(address(confidential), type(uint256).max);
        confidential.deposit(usd(100));
        vm.stopPrank();

        assertEq(confidential.totalWrapped(), usd(100));
        // Post-deposit the encrypted balance is no longer the identity ciphertext.
        ConfidentialToken.Ciphertext memory bal = confidential.encryptedBalanceOf(felix);
        assertTrue(bal.c2.x != 0 || bal.c2.y != 0);
    }

    function test_confidential_deposit_requires_registration() public {
        vm.startPrank(felix);
        usdg.approve(address(confidential), type(uint256).max);
        vm.expectRevert(AccountNotRegistered.selector);
        confidential.deposit(usd(100));
        vm.stopPrank();
    }

    function test_confidential_transfer_and_withdraw() public {
        (uint256 fx, uint256 fy) = pk(2);
        (uint256 gx, uint256 gy) = pk(3);

        vm.startPrank(felix);
        confidential.register(fx, fy);
        usdg.approve(address(confidential), type(uint256).max);
        confidential.deposit(usd(100));
        vm.stopPrank();

        vm.prank(gwen);
        confidential.register(gx, gy);

        // The transfer carries encrypted deltas; the stub waves the proof through.
        ConfidentialToken.Ciphertext memory delta = confidential.encryptedBalanceOf(gwen); // identity ciphertext
        uint256[] memory signals = new uint256[](0);

        vm.prank(felix);
        confidential.confidentialTransfer(gwen, delta, delta, "", signals);

        // Withdrawing returns the underlying asset.
        vm.prank(felix);
        confidential.withdraw(usd(40), "", signals);
        assertEq(usdg.balanceOf(felix), usd(900) + usd(40));
        assertEq(confidential.totalWrapped(), usd(60));
    }

    function test_confidential_verifier_rotation_guarded() public {
        IConfidentialTransferVerifier next =
            IConfidentialTransferVerifier(address(new StubTransferVerifier()));

        vm.expectRevert(Unauthorized.selector);
        vm.prank(felix);
        confidential.setVerifier(next);

        vm.prank(admin);
        confidential.setVerifier(next);
        assertEq(address(confidential.verifier()), address(next));
    }
}
