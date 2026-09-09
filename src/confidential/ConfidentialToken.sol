// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "../libraries/ReentrancyGuard.sol";
import {AltBn128} from "./AltBn128.sol";
import {IConfidentialTransferVerifier} from "./IConfidentialTransferVerifier.sol";
import "../libraries/ProtocolErrors.sol";

/// @title ConfidentialToken
/// @notice The privacy primitive everything else is arranged around: a wrapper
///         that turns a plain ERC-20 such as USDG into balances nobody but their
///         owner can read. Balances and transfer amounts live as ElGamal
///         ciphertexts on the alt_bn128 curve, and a zero-knowledge proof
///         checked on-chain establishes that each transfer is sound without
///         disclosing a single value. Who paid whom stays public. How much does
///         not.
///
/// @dev The shape of it:
///      - An account registers an ElGamal public key and from then on carries
///        one ciphertext balance `(c1, c2)`.
///      - {deposit} wraps the underlying asset by folding `amount * G` into `c2`
///        with zero randomness — the ordinary Zether funding step — which leaves
///        the running balance readable to the depositor's own view key.
///      - {confidentialTransfer} accepts two ElGamal deltas, one encrypting
///        `-amount` to the sender and one encrypting `+amount` to the recipient,
///        with a proof. The verifier insists both carry the same non-negative
///        figure and that the sender remains solvent; the contract then applies
///        each delta by point addition, which is why no amount ever appears in
///        calldata or in storage.
///      - {withdraw} unwraps against a proof that the encrypted balance covers
///        the figure.
///
///      The verifier sits behind {setVerifier} precisely so the circuits can be
///      replaced without migrating balances.
contract ConfidentialToken is ReentrancyGuard {
    using SafeTransferLib for IERC20;
    using AltBn128 for AltBn128.Point;

    /// @notice Thrown when a wrap, unwrap, or transfer is attempted while this
    ///         layer is frozen.
    error TokenPaused();

    /// @notice Thrown when someone other than the nominated successor tries to
    ///         complete an authority handoff.
    error NotPendingAuthority();

    struct Ciphertext {
        AltBn128.Point c1;
        AltBn128.Point c2;
    }

    /// @notice The asset being wrapped — USDG on Robinhood Chain.
    IERC20 public immutable asset;

    /// @notice Who may replace the verifier and work this layer's freeze.
    address public authority;

    /// @notice Successor nominated for that role, powerless until it calls
    ///         {acceptAuthority}. Losing this key to a typo would mean losing
    ///         control of both the verifier and the freeze.
    address public pendingAuthority;

    /// @notice The contract checking transfer and withdrawal proofs.
    IConfidentialTransferVerifier public verifier;

    /// @notice Each account's registered ElGamal public key.
    mapping(address => AltBn128.Point) internal _publicKey;
    mapping(address => bool) public registered;

    /// @notice Each account's encrypted balance.
    mapping(address => Ciphertext) internal _balance;

    /// @notice How much of the underlying asset the pool holds, tracked so the
    ///         wrapper can be shown to remain fully backed.
    uint256 public totalWrapped;

    /// @notice Freeze for this layer alone. While set, deposits, withdrawals,
    ///         and transfers all revert, but registration and verifier rotation
    ///         keep working — which is what allows a suspect verifier to be
    ///         swapped out, or a problem with the underlying asset to be waited
    ///         out, without accounts being stranded.
    bool public paused;

    event Registered(address indexed account, uint256 pkX, uint256 pkY);
    event Deposited(address indexed account, uint256 amount);
    event ConfidentialTransfer(address indexed from, address indexed to);
    event Withdrawn(address indexed account, uint256 amount);
    event VerifierUpdated(address indexed verifier);
    event PauseToggled(bool paused);
    event AuthorityTransferStarted(
        address indexed currentAuthority, address indexed pendingAuthority
    );
    event AuthorityTransferAccepted(
        address indexed previousAuthority, address indexed newAuthority
    );

    modifier onlyAuthority() {
        if (msg.sender != authority) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert TokenPaused();
        _;
    }

    constructor(IERC20 asset_, IConfidentialTransferVerifier verifier_, address authority_) {
        if (
            address(asset_) == address(0) || address(verifier_) == address(0)
                || authority_ == address(0)
        ) revert ZeroAddress();
        asset = asset_;
        verifier = verifier_;
        authority = authority_;
    }

    // ── Getting an account ───────────────────────────────────────────────────

    /// @notice Records the caller's ElGamal public key and opens an empty
    ///         encrypted balance. Required once, before any deposit.
    /// @dev The key has to be a genuine curve point, and registration is the one
    ///      cheap moment to insist on it. Let a malformed key through and every
    ///      ciphertext ever credited to the account becomes impossible to
    ///      decrypt, while non-points are fed into the homomorphic balance
    ///      arithmetic permanently.
    /// @param pkX X coordinate of the public key point.
    /// @param pkY Y coordinate of the public key point.
    function register(uint256 pkX, uint256 pkY) external {
        if (registered[msg.sender]) revert AccountAlreadyRegistered();
        if (!AltBn128.isOnCurve(AltBn128.Point(pkX, pkY))) revert InvalidPublicKey();

        _publicKey[msg.sender] = AltBn128.Point(pkX, pkY);
        registered[msg.sender] = true;
        // The opening balance is the identity ciphertext, which reads as zero.
        emit Registered(msg.sender, pkX, pkY);
    }

    // ── In and out ───────────────────────────────────────────────────────────

    /// @notice Wraps `amount` of the underlying asset into the caller's
    ///         encrypted balance, folding `amount * G` into the message
    ///         component with zero randomness so the result stays readable to
    ///         the caller's own view key.
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (!registered[msg.sender]) revert AccountNotRegistered();
        if (amount == 0) revert InvalidSpendAmount();

        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = asset.balanceOf(address(this)) - before;

        Ciphertext storage bal = _balance[msg.sender];
        bal.c2 = bal.c2.add(AltBn128.encode(received));
        totalWrapped += received;

        emit Deposited(msg.sender, received);
    }

    /// @notice Unwraps `amount` of the underlying asset back to the caller.
    /// @dev The proof has to demonstrate the encrypted balance covers the
    ///      figure. Given that, the contract removes `amount * G` from the
    ///      message component and releases the asset.
    /// @param amount How much to unwrap. It is public here, and there is no
    ///        point pretending otherwise: the ERC-20 transfer that follows is
    ///        itself public.
    /// @param proof The withdrawal proof.
    /// @param publicSignals Circuit public inputs; see the verifier.
    function withdraw(uint256 amount, bytes calldata proof, uint256[] calldata publicSignals)
        external
        nonReentrant
        whenNotPaused
    {
        if (!registered[msg.sender]) revert AccountNotRegistered();
        if (amount == 0) revert InvalidSpendAmount();
        if (!verifier.verifyWithdraw(proof, publicSignals)) revert ProofRejected();

        Ciphertext storage bal = _balance[msg.sender];
        bal.c2 = bal.c2.add(AltBn128.encode(amount).negate());
        totalWrapped -= amount;

        asset.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ── Moving value privately ───────────────────────────────────────────────

    /// @notice Sends an encrypted amount from the caller to `to`. The figure is
    ///         never stated; it is carried entirely by the two deltas and pinned
    ///         down by the proof.
    /// @param to The recipient, which must already be registered.
    /// @param senderDelta `-amount`, encrypted to the sender's own key.
    /// @param recipientDelta `+amount`, encrypted to the recipient's key.
    /// @param proof Ties both deltas to one figure and shows the sender stays
    ///        solvent.
    /// @param publicSignals Circuit public inputs; see the verifier.
    function confidentialTransfer(
        address to,
        Ciphertext calldata senderDelta,
        Ciphertext calldata recipientDelta,
        bytes calldata proof,
        uint256[] calldata publicSignals
    ) external nonReentrant whenNotPaused {
        if (!registered[msg.sender]) revert AccountNotRegistered();
        if (!registered[to]) revert AccountNotRegistered();
        if (to == msg.sender) revert Unauthorized();
        if (!verifier.verifyTransfer(proof, publicSignals)) revert ProofRejected();

        Ciphertext storage from = _balance[msg.sender];
        from.c1 = from.c1.add(senderDelta.c1);
        from.c2 = from.c2.add(senderDelta.c2);

        Ciphertext storage recv = _balance[to];
        recv.c1 = recv.c1.add(recipientDelta.c1);
        recv.c2 = recv.c2.add(recipientDelta.c2);

        emit ConfidentialTransfer(msg.sender, to);
    }

    // ── Administration ───────────────────────────────────────────────────────

    /// @notice Replaces the proof verifier, typically to move to upgraded
    ///         circuits.
    function setVerifier(IConfidentialTransferVerifier newVerifier) external onlyAuthority {
        if (address(newVerifier) == address(0)) revert ZeroAddress();
        verifier = newVerifier;
        emit VerifierUpdated(address(newVerifier));
    }

    /// @notice Freezes or unfreezes value movement on this layer. Registration
    ///         and verifier rotation are left alive deliberately, so the pool
    ///         can be repaired rather than redeployed.
    function setPaused(bool paused_) external onlyAuthority {
        paused = paused_;
        emit PauseToggled(paused_);
    }

    /// @notice Nominates the next authority without surrendering the role. The
    ///         nominee claims it through {acceptAuthority}.
    /// @dev The same two-step handoff {ProtocolAuthority} uses. The role here
    ///      controls the verifier and the freeze, so handing it to an address
    ///      nobody holds would be unrecoverable; making the recipient sign for
    ///      it removes that possibility. Nominating the zero address withdraws
    ///      an outstanding nomination.
    function beginAuthorityTransfer(address newAuthority) external onlyAuthority {
        pendingAuthority = newAuthority;
        emit AuthorityTransferStarted(authority, newAuthority);
    }

    /// @notice Claims the role nominated through {beginAuthorityTransfer}.
    function acceptAuthority() external {
        if (msg.sender != pendingAuthority) revert NotPendingAuthority();
        address previous = authority;
        authority = msg.sender;
        pendingAuthority = address(0);
        emit AuthorityTransferAccepted(previous, msg.sender);
    }

    // ── Reads ────────────────────────────────────────────────────────────────

    function publicKeyOf(address account) external view returns (uint256 x, uint256 y) {
        AltBn128.Point storage p = _publicKey[account];
        return (p.x, p.y);
    }

    /// @notice The raw ciphertext balance. Turning it back into a figure takes
    ///         the account's view key, which this contract has never seen.
    function encryptedBalanceOf(address account) external view returns (Ciphertext memory) {
        return _balance[account];
    }
}
