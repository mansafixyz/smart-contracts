// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IProtocolAuthority} from "./interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "./interfaces/IAccountRegistry.sol";
import {IFeeSchedule} from "./fees/IFeeSchedule.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "./libraries/ReentrancyGuard.sol";
import "./libraries/ProtocolErrors.sol";

/// @title RequestLedger
/// @notice The records sitting behind every request link and payment QR code.
///
/// @dev Someone writes a request, shares the link, and whoever opens it pays the
///      exact asset and amount it names. Since privacy is the default here, a
///      request can withhold its own amount: rather than writing the figure into
///      storage it writes a commitment to the figure, and {fulfill} tests the
///      payer's claimed amount against that commitment before any value moves.
///
///      The transfer this contract performs is an ordinary ERC-20 transfer.
///      Hiding the figure the whole way through means pairing a confidential
///      request with a {ConfidentialToken} transfer when it settles, an
///      arrangement the client makes on its own. What lives here is the lifecycle and the commitment check —
///      not the encryption.
contract RequestLedger is ReentrancyGuard {
    using SafeTransferLib for IERC20;

    enum RequestStatus {
        Open,
        Fulfilled,
        Cancelled
    }

    struct Request {
        address requester; // account that raised the request
        address receiver; // where the funds go when it is paid
        address token;
        bool isConfidential;
        uint256 amount; // the figure in the clear; zero when confidential
        bytes32 amountCommitment; // what the payer's figure must reproduce
        bytes32 memoHash; // hash of the encrypted memo
        RequestStatus status;
        uint64 createdAt;
        uint64 expiresAt;
        bool exists;
        address payer; // who settled it; zero until fulfilled
        uint64 fulfilledAt; // when; zero until fulfilled
    }

    IProtocolAuthority public immutable protocol;
    IAccountRegistry public immutable registry;

    uint256 public requestCount;
    mapping(uint256 => Request) internal _requests;

    /// @notice Request ids per creator, in the order they were raised, so a
    ///         wallet can list its own links without trawling the event log.
    mapping(address => uint256[]) internal _requestsByRequester;

    event PaymentRequestCreated(
        uint256 indexed requestId,
        address indexed requester,
        address token,
        bool isConfidential,
        uint256 amount,
        uint64 expiresAt,
        uint256 timestamp
    );
    event PaymentRequestFulfilled(
        uint256 indexed requestId, address indexed payer, uint256 amount, uint256 timestamp
    );
    event PaymentRequestCancelled(uint256 indexed requestId, uint256 timestamp);
    event ProtocolFeeCharged(
        uint256 indexed requestId, address indexed treasury, uint256 fee, uint256 timestamp
    );

    constructor(IProtocolAuthority protocol_, IAccountRegistry registry_) {
        if (address(protocol_) == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress();
        }
        protocol = protocol_;
        registry = registry_;
    }

    /// @notice Raises a request to be shared as a link or a QR code.
    /// @dev A confidential request passes `isConfidential = true`, `amount = 0`,
    ///      and a genuine `amountCommitment`. The payer learns the figure and its
    ///      blinding factor out of band — normally from the request's encrypted
    ///      memo — and hands both back to {fulfill}.
    /// @param receiver Destination for the funds. It need not be the requester's
    ///        own wallet, so a business can route receipts straight to a treasury.
    function create(
        address receiver,
        address token,
        bool isConfidential,
        uint256 amount,
        bytes32 amountCommitment,
        bytes32 memoHash,
        uint64 expiresAt
    ) external returns (uint256 requestId) {
        if (!registry.isRegistered(msg.sender)) revert ProfileNotFound();
        if (receiver == address(0) || token == address(0)) revert ZeroAddress();
        if (expiresAt <= block.timestamp) revert InvalidExpiry();
        if (!isConfidential && amount == 0) revert InvalidSpendAmount();
        // A confidential request with no commitment could never be paid, since
        // fulfill would compare the payer's figure against zero and refuse.
        if (isConfidential && amountCommitment == bytes32(0)) revert MissingCommitment();

        requestId = ++requestCount;
        _requests[requestId] = Request({
            requester: msg.sender,
            receiver: receiver,
            token: token,
            isConfidential: isConfidential,
            amount: isConfidential ? 0 : amount,
            amountCommitment: isConfidential ? amountCommitment : bytes32(0),
            memoHash: memoHash,
            status: RequestStatus.Open,
            createdAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            exists: true,
            payer: address(0),
            fulfilledAt: 0
        });
        _requestsByRequester[msg.sender].push(requestId);

        emit PaymentRequestCreated(
            requestId,
            msg.sender,
            token,
            isConfidential,
            isConfidential ? 0 : amount,
            expiresAt,
            block.timestamp
        );
    }

    /// @notice Pays an open request and closes it.
    /// @dev An ordinary request demands `amount` equal what was stored. A
    ///      confidential one demands the figure and blinding factor the
    ///      requester shared privately, and checks that
    ///      `keccak256(amount, blinding)` reproduces the stored commitment. That
    ///      catches a payer working from the wrong figure without the correct
    ///      one ever having been written on-chain.
    function fulfill(uint256 requestId, uint256 amount, bytes32 blinding) external nonReentrant {
        if (protocol.paused()) revert ProtocolPaused();

        Request storage r = _requests[requestId];
        if (r.status != RequestStatus.Open) revert RequestNotOpen();
        if (block.timestamp >= r.expiresAt) revert RequestExpired();

        if (r.isConfidential) {
            if (keccak256(abi.encodePacked(amount, blinding)) != r.amountCommitment) {
                revert RequestCommitmentMismatch();
            }
        } else if (amount != r.amount) {
            revert RequestAmountMismatch();
        }

        r.status = RequestStatus.Fulfilled;
        r.payer = msg.sender;
        r.fulfilledAt = uint64(block.timestamp);

        // Whoever pays is the one using the protocol, so the fee is added on top
        // of their payment and the recipient is left whole. The payer's own held
        // and staked $MANSA set the discount. With fee routing unwired the fee
        // comes back zero and this reduces to a plain transfer.
        (uint256 fee, address treasury) = _quoteFee(msg.sender, amount);

        IERC20(r.token).safeTransferFrom(msg.sender, r.receiver, amount);
        if (fee > 0) {
            IERC20(r.token).safeTransferFrom(msg.sender, treasury, fee);
            emit ProtocolFeeCharged(requestId, treasury, fee, block.timestamp);
        }

        emit PaymentRequestFulfilled(requestId, msg.sender, amount, block.timestamp);
    }

    /// @dev Prices the fee owed on a fulfillment, discounted by the payer's held
    ///      and staked $MANSA. Returns nothing while fees are switched off
    ///      protocol-wide.
    function _quoteFee(address payer, uint256 amount)
        internal
        view
        returns (uint256 fee, address treasury)
    {
        address schedule = protocol.feeSchedule();
        treasury = protocol.treasury();
        if (schedule == address(0) || treasury == address(0)) return (0, address(0));
        (fee,) = IFeeSchedule(schedule).quoteFee(payer, amount);
    }

    /// @notice Withdraws a request that has not yet been paid. Only its creator
    ///         may do so.
    function cancel(uint256 requestId) external {
        Request storage r = _requests[requestId];
        if (r.requester != msg.sender) revert Unauthorized();
        if (r.status != RequestStatus.Open) revert RequestNotOpen();

        r.status = RequestStatus.Cancelled;
        emit PaymentRequestCancelled(requestId, block.timestamp);
    }

    function getRequest(uint256 requestId) external view returns (Request memory) {
        return _requests[requestId];
    }

    /// @notice How many requests a wallet has raised.
    function requestCountOf(address requester) external view returns (uint256) {
        return _requestsByRequester[requester].length;
    }

    /// @notice Every request id a wallet has raised, oldest first. Pair with
    ///         {getRequest} to render its outstanding links.
    function requestIdsOf(address requester) external view returns (uint256[] memory) {
        return _requestsByRequester[requester];
    }

    /// @notice One page of a wallet's request ids, oldest first, beginning at
    ///         `offset` and running at most `limit` long. A busy business
    ///         account will eventually raise more requests than the unpaged view
    ///         can return in a single RPC response, so a client steps through
    ///         this instead, advancing `offset` until a short page arrives.
    function requestIdsOf(address requester, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory page)
    {
        uint256[] storage all = _requestsByRequester[requester];
        uint256 total = all.length;
        if (offset >= total) return new uint256[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = all[i];
        }
    }

    /// @notice Whether a request can be paid at this moment: it exists, nobody
    ///         has closed it, and it has not run out of time. Saves a client
    ///         from reimplementing {fulfill}'s preconditions before drawing a
    ///         pay button.
    function isFulfillable(uint256 requestId) external view returns (bool) {
        Request storage r = _requests[requestId];
        return r.exists && r.status == RequestStatus.Open && block.timestamp < r.expiresAt;
    }
}
