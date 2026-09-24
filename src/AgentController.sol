// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IProtocolAuthority} from "./interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "./interfaces/IAccountRegistry.sol";
import {IFeeSchedule} from "./fees/IFeeSchedule.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "./libraries/ReentrancyGuard.sol";
import "./libraries/ProtocolErrors.sol";

/// @title AgentController
/// @notice Gives autonomous software a wallet it can actually spend from, and
///         gives the person behind it limits the chain enforces rather than a
///         server promises.
///
/// @dev The arrangement rests on one idea: make the agent's key weak enough that
///      losing it is survivable. An agent signs with `agentSigner`, held by
///      whatever system runs it, and that key can do exactly three things —
///      spend from a vault this contract controls, in one nominated token, and
///      only inside the policy its owner wrote. It cannot withdraw, cannot
///      re-key itself, and cannot widen its own limits. Because funds never rest
///      under the agent's key, a leak is answered by pausing or revoking the
///      agent rather than by racing it to empty an account.
///
///      Vaults are internal balances rather than separate contracts. This
///      contract holds the pooled ERC-20 and attributes each agent's share in
///      `vaultBalance`, which means one agent's funds are unreachable to another
///      by construction rather than by check.
///
///      x402 runs through here natively: both settlement paths carry the
///      `invoiceId` from an HTTP 402 challenge into the event stream, which is
///      what an operator's webhook reconciles against afterwards.
contract AgentController is ReentrancyGuard {
    using SafeTransferLib for IERC20;

    /// @notice Thrown when a rotation names the key the agent is already using.
    error SameSigner();

    /// @notice How much rope an agent gets before a person has to weigh in.
    enum AutonomyTier {
        /// Nothing settles directly; every spend waits for approval.
        Supervised,
        /// Settles up to the approval threshold, queues above it.
        SemiAutonomous,
        /// Settles anything the policy permits.
        FullyAutonomous
    }

    enum AgentStatus {
        Active,
        Paused,
        Revoked
    }

    /// @notice What would happen to a spend if the agent submitted it now.
    enum SpendRoute {
        /// {payInvoice} would settle it on the spot.
        Settles,
        /// {queueInvoice} would park it for the owner to decide on.
        Queues,
        /// Neither path accepts it as things stand.
        Refused
    }

    struct Agent {
        address ownerProfile; // the wallet that owns this agent
        address agentSigner; // key the running agent submits spends with
        string label; // something readable, like "coding-assistant"
        AutonomyTier autonomyTier;
        AgentStatus status;
        uint64 createdAt;
        bool exists;
    }

    /// @notice The rules binding one agent, for one token.
    struct SpendPolicy {
        address token; // the only asset this agent may move
        uint256 perTxLimit; // ceiling on any single settled spend
        uint256 dailyLimit; // ceiling across a rolling 24 hours
        uint256 hitlThreshold; // anything strictly above this needs a person
        uint64 windowStart; // when the current rolling window opened
        uint256 windowSpent; // settled so far inside that window
        bool allowlistEnabled; // when set, only allowedRecipients may be paid
        address[] allowedRecipients;
        uint64 updatedAt;
    }

    /// @notice A spend parked awaiting a human decision. Nothing has moved.
    struct PendingApproval {
        uint256 agentId;
        address ownerProfile;
        address recipient;
        address token;
        uint256 amount;
        bytes32 invoiceId; // x402 reference, or zero for an ordinary spend
        bytes32 memoHash; // hash of the encrypted memo shown to the approver
        uint64 createdAt;
        bool exists;
    }

    uint256 internal constant MAX_LABEL_LEN = 40;
    uint256 internal constant MAX_ALLOWED_RECIPIENTS = 10;
    uint256 internal constant WINDOW = 1 days;

    IProtocolAuthority public immutable protocol;
    IAccountRegistry public immutable registry;

    uint256 public agentCount;

    mapping(uint256 => Agent) internal _agents;
    mapping(uint256 => SpendPolicy) internal _policies;
    mapping(uint256 => uint256) public vaultBalance; // agentId => tokens attributed to it
    mapping(uint256 => uint256) public pendingCount; // agentId => next pending id
    mapping(uint256 => mapping(uint256 => PendingApproval)) internal _pending;

    /// @notice Agent ids per owning account, in the order they were created, so
    ///         a wallet can list its agents without replaying the event log.
    ///         Revoked agents stay in the list; their status says so.
    mapping(address => uint256[]) internal _agentsByOwner;

    event AgentCreated(
        uint256 indexed agentId,
        address indexed ownerProfile,
        address indexed agentSigner,
        string label,
        AutonomyTier autonomyTier,
        address token,
        uint256 timestamp
    );
    event SpendPolicyUpdated(
        uint256 indexed agentId,
        uint256 perTxLimit,
        uint256 dailyLimit,
        uint256 hitlThreshold,
        bool allowlistEnabled,
        address[] allowedRecipients,
        uint256 timestamp
    );
    event AgentStatusChanged(uint256 indexed agentId, AgentStatus status, uint256 timestamp);
    event AgentSignerRotated(
        uint256 indexed agentId,
        address indexed previousSigner,
        address indexed newSigner,
        uint256 timestamp
    );
    event AgentFunded(
        uint256 indexed agentId, address indexed funder, uint256 amount, uint256 timestamp
    );
    event AgentDefunded(
        uint256 indexed agentId, address indexed owner, uint256 amount, uint256 timestamp
    );
    event AgentPaymentExecuted(
        uint256 indexed agentId,
        address indexed recipient,
        address token,
        uint256 amount,
        bytes32 invoiceId,
        uint256 windowSpent,
        uint256 timestamp
    );
    event ApprovalRequired(
        uint256 indexed agentId,
        uint256 indexed pendingId,
        address indexed recipient,
        address token,
        uint256 amount,
        bytes32 invoiceId,
        uint256 timestamp
    );
    event PendingPaymentApproved(
        uint256 indexed agentId,
        uint256 indexed pendingId,
        address indexed recipient,
        uint256 amount,
        uint256 timestamp
    );
    event PendingPaymentRejected(
        uint256 indexed agentId, uint256 indexed pendingId, uint256 timestamp
    );
    event PendingPaymentWithdrawn(
        uint256 indexed agentId, uint256 indexed pendingId, uint256 timestamp
    );
    event ProtocolFeeCharged(
        uint256 indexed agentId, address indexed treasury, uint256 fee, uint256 timestamp
    );

    constructor(IProtocolAuthority protocol_, IAccountRegistry registry_) {
        if (address(protocol_) == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress();
        }
        protocol = protocol_;
        registry = registry_;
    }

    // ── Guards ───────────────────────────────────────────────────────────────

    modifier whenNotPaused() {
        if (protocol.paused()) revert ProtocolPaused();
        _;
    }

    modifier onlyAgentOwner(uint256 agentId) {
        if (_agents[agentId].ownerProfile != msg.sender) revert UnauthorizedAgentOwner();
        _;
    }

    modifier onlyAgentSigner(uint256 agentId) {
        if (_agents[agentId].agentSigner != msg.sender) revert UnauthorizedAgentSigner();
        _;
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    /// @notice Registers an agent beneath the caller's account together with the
    ///         policy it will run under. The vault is the balance tracked
    ///         against the returned `agentId`; put funds in it with {fundAgent}.
    /// @param agentSigner The key the running agent will sign with. Only its
    ///        address is recorded here; it does not sign this call.
    /// @param label Something readable, 1 to 40 characters.
    /// @param token The single asset the agent is permitted to move.
    function createAgent(
        address agentSigner,
        string calldata label,
        AutonomyTier autonomyTier,
        address token,
        uint256 perTxLimit,
        uint256 dailyLimit,
        uint256 hitlThreshold,
        address[] calldata allowedRecipients,
        bool allowlistEnabled
    ) external returns (uint256 agentId) {
        if (!registry.isRegistered(msg.sender)) revert ProfileNotFound();
        if (agentSigner == address(0) || token == address(0)) revert ZeroAddress();

        uint256 len = bytes(label).length;
        if (len == 0 || len > MAX_LABEL_LEN) revert InvalidLabelLength();
        _validateLimits(perTxLimit, dailyLimit, hitlThreshold, allowedRecipients.length);

        agentId = ++agentCount;

        _agents[agentId] = Agent({
            ownerProfile: msg.sender,
            agentSigner: agentSigner,
            label: label,
            autonomyTier: autonomyTier,
            status: AgentStatus.Active,
            createdAt: uint64(block.timestamp),
            exists: true
        });

        SpendPolicy storage p = _policies[agentId];
        p.token = token;
        p.perTxLimit = perTxLimit;
        p.dailyLimit = dailyLimit;
        p.hitlThreshold = hitlThreshold;
        p.windowStart = uint64(block.timestamp);
        p.allowlistEnabled = allowlistEnabled;
        p.allowedRecipients = allowedRecipients;
        p.updatedAt = uint64(block.timestamp);
        _agentsByOwner[msg.sender].push(agentId);

        emit AgentCreated(
            agentId, msg.sender, agentSigner, label, autonomyTier, token, block.timestamp
        );
        emit SpendPolicyUpdated(
            agentId,
            perTxLimit,
            dailyLimit,
            hitlThreshold,
            allowlistEnabled,
            allowedRecipients,
            block.timestamp
        );
    }

    /// @notice Rewrites an agent's ceilings, approval threshold, and allowlist.
    ///         Reserved to the owning account — an agent has no standing to
    ///         relax the rules it runs under.
    function updateSpendPolicy(
        uint256 agentId,
        uint256 perTxLimit,
        uint256 dailyLimit,
        uint256 hitlThreshold,
        bool allowlistEnabled,
        address[] calldata allowedRecipients
    ) external onlyAgentOwner(agentId) {
        _validateLimits(perTxLimit, dailyLimit, hitlThreshold, allowedRecipients.length);

        SpendPolicy storage p = _policies[agentId];
        p.perTxLimit = perTxLimit;
        p.dailyLimit = dailyLimit;
        p.hitlThreshold = hitlThreshold;
        p.allowlistEnabled = allowlistEnabled;
        p.allowedRecipients = allowedRecipients;
        p.updatedAt = uint64(block.timestamp);

        emit SpendPolicyUpdated(
            agentId,
            perTxLimit,
            dailyLimit,
            hitlThreshold,
            allowlistEnabled,
            allowedRecipients,
            block.timestamp
        );
    }

    /// @notice Halts or restarts an agent, leaving vault and policy as they are.
    ///         Reach for this on a suspected key leak or during maintenance;
    ///         {revokeAgent} is the permanent option.
    function setAgentStatus(uint256 agentId, AgentStatus status) external onlyAgentOwner(agentId) {
        if (status == AgentStatus.Revoked) revert AgentAlreadyRevoked();
        Agent storage a = _agents[agentId];
        if (a.status == AgentStatus.Revoked) revert AgentAlreadyRevoked();

        a.status = status;
        emit AgentStatusChanged(agentId, status, block.timestamp);
    }

    /// @notice Swaps the key an agent signs with, preserving its vault, policy,
    ///         and spend history.
    /// @dev The middle path for a leaked key. Instead of tearing the agent down
    ///      and rebuilding everything around it, pause it, point it at a freshly
    ///      generated signer, and resume. Rotation belongs to the owner alone;
    ///      an agent cannot re-key itself, and a revoked agent stays revoked.
    function rotateAgentSigner(uint256 agentId, address newSigner)
        external
        onlyAgentOwner(agentId)
    {
        if (newSigner == address(0)) revert ZeroAddress();
        Agent storage a = _agents[agentId];
        if (a.status == AgentStatus.Revoked) revert AgentAlreadyRevoked();
        if (a.agentSigner == newSigner) revert SameSigner();

        address previous = a.agentSigner;
        a.agentSigner = newSigner;
        emit AgentSignerRotated(agentId, previous, newSigner, block.timestamp);
    }

    /// @notice Retires an agent for good and returns whatever is left in its
    ///         vault to the owner in the same transaction. There is no undo, so
    ///         a compromised or finished agent's key can never be honoured again.
    function revokeAgent(uint256 agentId) external nonReentrant onlyAgentOwner(agentId) {
        Agent storage a = _agents[agentId];
        if (a.status == AgentStatus.Revoked) revert AgentAlreadyRevoked();

        a.status = AgentStatus.Revoked;

        uint256 remaining = vaultBalance[agentId];
        if (remaining > 0) {
            vaultBalance[agentId] = 0;
            IERC20(_policies[agentId].token).safeTransfer(msg.sender, remaining);
        }

        emit AgentStatusChanged(agentId, AgentStatus.Revoked, block.timestamp);
    }

    // ── Vault ────────────────────────────────────────────────────────────────

    /// @notice Moves settlement tokens into an agent's vault. Anyone may fund an
    ///         agent, though in practice it is the owner. The agent has no way
    ///         to pull funds toward itself; every credit is somebody's decision.
    function fundAgent(uint256 agentId, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidSpendAmount();
        Agent storage a = _agents[agentId];
        if (!a.exists) revert AgentNotActive();
        if (a.status == AgentStatus.Revoked) revert AgentAlreadyRevoked();

        // Credit what actually arrived rather than what was asked for, so a
        // fee-on-transfer token cannot leave this contract's books overstated.
        IERC20 token = IERC20(_policies[agentId].token);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;

        vaultBalance[agentId] += received;
        emit AgentFunded(agentId, msg.sender, received, block.timestamp);
    }

    /// @notice Draws part of a vault back to the owner while the agent keeps
    ///         running. Without this, correcting an overfunded vault would mean
    ///         {revokeAgent}, which cannot be undone.
    /// @dev Intentionally outside both the protocol pause and the agent's own
    ///      status, on the same reasoning as {revokeAgent}: a route for pulling
    ///      your money back has to stay open precisely during an incident. The
    ///      agent's key can never reach it — only the owning account can.
    function withdrawFromAgent(uint256 agentId, uint256 amount)
        external
        nonReentrant
        onlyAgentOwner(agentId)
    {
        if (amount == 0) revert InvalidSpendAmount();
        if (amount > vaultBalance[agentId]) revert InsufficientVaultBalance();

        vaultBalance[agentId] -= amount;
        IERC20(_policies[agentId].token).safeTransfer(msg.sender, amount);

        emit AgentDefunded(agentId, msg.sender, amount, block.timestamp);
    }

    // ── Spending ─────────────────────────────────────────────────────────────

    /// @notice Settles a spend on the spot, as far as the agent's tier allows.
    ///         Signed by the agent's own key.
    /// @dev Tier decides how far the agent gets alone. A Supervised agent
    ///      settles nothing here and must use {queueInvoice}; a SemiAutonomous
    ///      one settles up to its approval threshold; a FullyAutonomous one
    ///      settles whatever the policy permits. Per-transaction ceiling, daily
    ///      ceiling, and allowlist bind all three — full autonomy widens the
    ///      band that settles directly, it never loosens the policy itself.
    /// @param invoiceId x402 reference to stamp on the settlement event, or zero
    ///        for a plain transfer.
    function payInvoice(uint256 agentId, address recipient, uint256 amount, bytes32 invoiceId)
        external
        nonReentrant
        whenNotPaused
        onlyAgentSigner(agentId)
    {
        if (amount == 0) revert InvalidSpendAmount();
        if (recipient == address(0)) revert ZeroAddress();
        Agent storage a = _agents[agentId];
        if (a.status != AgentStatus.Active) revert AgentNotActive();
        if (a.autonomyTier == AutonomyTier.Supervised) revert TierRequiresApproval();

        SpendPolicy storage p = _policies[agentId];
        if (amount > p.perTxLimit) revert PerTransactionLimitExceeded();
        if (a.autonomyTier == AutonomyTier.SemiAutonomous && amount > p.hitlThreshold) {
            revert AmountExceedsHitlThreshold();
        }
        _checkAllowlist(p, recipient);

        _rollWindow(p);
        uint256 projected = p.windowSpent + amount;
        if (projected > p.dailyLimit) revert DailyLimitExceeded();

        (uint256 fee, address treasury) = _quoteFee(agentId, amount);
        if (amount + fee > vaultBalance[agentId]) revert InsufficientVaultBalance();

        // State settled before anything leaves the contract.
        p.windowSpent = projected;
        p.updatedAt = uint64(block.timestamp);
        vaultBalance[agentId] -= amount + fee;

        IERC20(p.token).safeTransfer(recipient, amount);
        if (fee > 0) {
            IERC20(p.token).safeTransfer(treasury, fee);
            emit ProtocolFeeCharged(agentId, treasury, fee, block.timestamp);
        }

        emit AgentPaymentExecuted(
            agentId, recipient, p.token, amount, invoiceId, projected, block.timestamp
        );
    }

    /// @notice Parks a spend for a human to decide on. Nothing moves until
    ///         {approvePending} runs.
    /// @dev A Supervised agent queues everything, and a FullyAutonomous one may
    ///      queue whatever it would rather have seen; only the SemiAutonomous
    ///      tier is held to queueing strictly above its threshold, since at or
    ///      below it {payInvoice} settles directly. Allowlist and per-transaction
    ///      ceiling are checked now so the queue cannot be flooded with spends
    ///      that were never going to pass. The daily ceiling is deliberately
    ///      left until approval: what fits inside today's remaining allowance at
    ///      the moment of queueing may not still fit when somebody looks at it.
    function queueInvoice(
        uint256 agentId,
        address recipient,
        uint256 amount,
        bytes32 invoiceId,
        bytes32 memoHash
    ) external whenNotPaused onlyAgentSigner(agentId) returns (uint256 pendingId) {
        if (amount == 0) revert InvalidSpendAmount();
        if (recipient == address(0)) revert ZeroAddress();
        Agent storage a = _agents[agentId];
        if (a.status != AgentStatus.Active) revert AgentNotActive();

        SpendPolicy storage p = _policies[agentId];
        if (amount > p.perTxLimit) revert PerTransactionLimitExceeded();
        if (a.autonomyTier == AutonomyTier.SemiAutonomous && amount <= p.hitlThreshold) {
            revert AmountWithinHitlThreshold();
        }
        _checkAllowlist(p, recipient);

        pendingId = pendingCount[agentId]++;
        _pending[agentId][pendingId] = PendingApproval({
            agentId: agentId,
            ownerProfile: a.ownerProfile,
            recipient: recipient,
            token: p.token,
            amount: amount,
            invoiceId: invoiceId,
            memoHash: memoHash,
            createdAt: uint64(block.timestamp),
            exists: true
        });

        emit ApprovalRequired(
            agentId, pendingId, recipient, p.token, amount, invoiceId, block.timestamp
        );
    }

    /// @notice The owner releases a queued spend. The policy is evaluated again
    ///         from scratch, because the allowlist, the per-transaction ceiling,
    ///         or the day's running total may all have moved since the spend was
    ///         parked.
    function approvePending(uint256 agentId, uint256 pendingId)
        external
        nonReentrant
        whenNotPaused
        onlyAgentOwner(agentId)
    {
        if (_agents[agentId].status != AgentStatus.Active) revert AgentNotActive();

        PendingApproval storage pa = _pending[agentId][pendingId];
        if (!pa.exists) revert PendingApprovalNotFound();

        uint256 amount = pa.amount;
        address recipient = pa.recipient;
        bytes32 invoiceId = pa.invoiceId;

        SpendPolicy storage p = _policies[agentId];
        _checkAllowlist(p, recipient);
        if (amount > p.perTxLimit) revert PerTransactionLimitExceeded();

        _rollWindow(p);
        uint256 projected = p.windowSpent + amount;
        if (projected > p.dailyLimit) revert DailyLimitExceeded();

        (uint256 fee, address treasury) = _quoteFee(agentId, amount);
        if (amount + fee > vaultBalance[agentId]) revert InsufficientVaultBalance();

        // State settled before anything leaves the contract.
        p.windowSpent = projected;
        p.updatedAt = uint64(block.timestamp);
        vaultBalance[agentId] -= amount + fee;
        delete _pending[agentId][pendingId];

        IERC20(p.token).safeTransfer(recipient, amount);
        if (fee > 0) {
            IERC20(p.token).safeTransfer(treasury, fee);
            emit ProtocolFeeCharged(agentId, treasury, fee, block.timestamp);
        }

        emit AgentPaymentExecuted(
            agentId, recipient, p.token, amount, invoiceId, projected, block.timestamp
        );
        emit PendingPaymentApproved(agentId, pendingId, recipient, amount, block.timestamp);
    }

    /// @notice The owner turns a queued spend down. Since nothing ever left the
    ///         vault there is nothing to return; the record is simply dropped.
    function rejectPending(uint256 agentId, uint256 pendingId) external onlyAgentOwner(agentId) {
        if (!_pending[agentId][pendingId].exists) revert PendingApprovalNotFound();
        delete _pending[agentId][pendingId];
        emit PendingPaymentRejected(agentId, pendingId, block.timestamp);
    }

    /// @notice The agent takes back a spend it queued and no longer needs, for
    ///         instance because the x402 challenge behind it has expired. Only
    ///         the record goes; nothing was ever moved. An owner turning a spend
    ///         down uses {rejectPending}, and the two are logged apart so a
    ///         timeline can tell who ended it.
    function withdrawPending(uint256 agentId, uint256 pendingId) external onlyAgentSigner(agentId) {
        if (!_pending[agentId][pendingId].exists) revert PendingApprovalNotFound();
        delete _pending[agentId][pendingId];
        emit PendingPaymentWithdrawn(agentId, pendingId, block.timestamp);
    }

    // ── Reads ────────────────────────────────────────────────────────────────

    function getAgent(uint256 agentId) external view returns (Agent memory) {
        return _agents[agentId];
    }

    function getPolicy(uint256 agentId) external view returns (SpendPolicy memory) {
        return _policies[agentId];
    }

    function getPending(uint256 agentId, uint256 pendingId)
        external
        view
        returns (PendingApproval memory)
    {
        return _pending[agentId][pendingId];
    }

    /// @notice How many agents an account has created, revoked ones included.
    function agentCountOf(address owner) external view returns (uint256) {
        return _agentsByOwner[owner].length;
    }

    /// @notice Every agent id an account has created, oldest first. Pair with
    ///         {getAgent} to hydrate each one.
    function agentIdsOf(address owner) external view returns (uint256[] memory) {
        return _agentsByOwner[owner];
    }

    /// @notice Which path a spend would take right now, or whether it would be
    ///         turned away by both. Mirrors the checks in {payInvoice} and
    ///         {queueInvoice} so an agent can find out before it spends gas,
    ///         and a UI can label the button correctly.
    /// @dev The daily ceiling and the vault balance are read against the live
    ///      window, and a spend that queues today is re-checked at approval
    ///      time, so `Queues` promises only that the record will be accepted.
    function routeFor(uint256 agentId, address recipient, uint256 amount)
        external
        view
        returns (SpendRoute)
    {
        Agent storage a = _agents[agentId];
        if (!a.exists || a.status != AgentStatus.Active) return SpendRoute.Refused;
        if (amount == 0 || recipient == address(0)) return SpendRoute.Refused;
        if (protocol.paused()) return SpendRoute.Refused;

        SpendPolicy storage p = _policies[agentId];
        if (amount > p.perTxLimit) return SpendRoute.Refused;
        if (!_isAllowed(p, recipient)) return SpendRoute.Refused;

        // Anything the tier hands to a person goes to the queue.
        if (a.autonomyTier == AutonomyTier.Supervised) return SpendRoute.Queues;
        if (a.autonomyTier == AutonomyTier.SemiAutonomous && amount > p.hitlThreshold) {
            return SpendRoute.Queues;
        }

        // The rest could settle directly, provided the day and the vault allow.
        uint256 spent = block.timestamp - p.windowStart >= WINDOW ? 0 : p.windowSpent;
        if (spent + amount > p.dailyLimit) return SpendRoute.Refused;
        (uint256 fee,) = _quoteFee(agentId, amount);
        if (amount + fee > vaultBalance[agentId]) return SpendRoute.Refused;

        return SpendRoute.Settles;
    }

    /// @notice What the agent could still spend in the current window, taking
    ///         into account a window that has already run out.
    function remainingDailyAllowance(uint256 agentId) external view returns (uint256) {
        SpendPolicy storage p = _policies[agentId];
        uint256 spent = block.timestamp - p.windowStart >= WINDOW ? 0 : p.windowSpent;
        return spent >= p.dailyLimit ? 0 : p.dailyLimit - spent;
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    /// @dev Prices the protocol fee on a spend, discounted by the owner's held
    ///      and staked $MANSA. Returns nothing at all while fees are switched
    ///      off, so an agent created before fees existed keeps behaving exactly
    ///      as it did. The fee rides on top of the spend and comes out of the
    ///      same vault, but it is not counted against the policy: those limits
    ///      govern what the agent spends, not what the protocol charges to carry
    ///      it.
    function _quoteFee(uint256 agentId, uint256 amount)
        internal
        view
        returns (uint256 fee, address treasury)
    {
        address schedule = protocol.feeSchedule();
        treasury = protocol.treasury();
        if (schedule == address(0) || treasury == address(0)) return (0, address(0));
        (fee,) = IFeeSchedule(schedule).quoteFee(_agents[agentId].ownerProfile, amount);
    }

    function _validateLimits(
        uint256 perTxLimit,
        uint256 dailyLimit,
        uint256 hitlThreshold,
        uint256 allowlistLen
    ) internal pure {
        if (hitlThreshold == 0) revert InvalidHitlThreshold();
        if (perTxLimit == 0 || dailyLimit == 0) revert InvalidSpendAmount();
        if (perTxLimit > dailyLimit) revert PerTxLimitExceedsDailyLimit();
        if (allowlistLen > MAX_ALLOWED_RECIPIENTS) revert TooManyAllowedRecipients();
    }

    function _checkAllowlist(SpendPolicy storage p, address recipient) internal view {
        if (!_isAllowed(p, recipient)) revert RecipientNotAllowed();
    }

    function _isAllowed(SpendPolicy storage p, address recipient) internal view returns (bool) {
        if (!p.allowlistEnabled) return true;
        address[] storage list = p.allowedRecipients;
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == recipient) return true;
        }
        return false;
    }

    /// @dev Advances the 24-hour window the first time a spend arrives more than
    ///      a day after it opened, which spares every client from having to call
    ///      a reset of its own.
    function _rollWindow(SpendPolicy storage p) internal {
        if (block.timestamp - p.windowStart >= WINDOW) {
            p.windowStart = uint64(block.timestamp);
            p.windowSpent = 0;
        }
    }
}
