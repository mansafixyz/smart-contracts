// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IProtocolAuthority} from "./interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "./interfaces/IAccountRegistry.sol";
import "./libraries/ProtocolErrors.sol";

/// @title AccountRegistry
/// @notice Where an address becomes somebody. Each wallet gets at most one
///         account record here, and each record reserves a `.mansafi` handle, so
///         a payment can be addressed to gwen.mansafi instead of forty hex
///         characters nobody wants to read aloud.
///
/// @dev Custodies nothing and blocks nothing. Confidentiality in this protocol
///      conceals amounts, never identity, so records are verified at creation
///      and the KYC tier recorded here is consumed by whatever enforces limits
///      elsewhere. Handles are kept lowercase, stripped of any leading at-sign
///      and of the `.mansafi` suffix; {fullHandle} reassembles the display form
///      on read rather than paying to store it.
contract AccountRegistry is IAccountRegistry {
    enum AccountKind {
        Personal,
        Business,
        AgentOperator
    }

    struct Profile {
        address owner;
        string handle;
        KycTier kycTier;
        AccountKind accountKind;
        uint64 createdAt;
        uint64 updatedAt;
        bool exists;
    }

    uint256 internal constant MAX_HANDLE_LEN = 32;
    string internal constant HANDLE_SUFFIX = ".mansafi";

    IProtocolAuthority public immutable protocol;

    /// @notice Account record by controlling wallet, one apiece.
    mapping(address => Profile) internal _profiles;

    /// @notice Hashed handle to the wallet holding it. Keying on the handle
    ///         makes both questions a client actually asks — is this name free,
    ///         and who does it point at — a single storage read, which is what
    ///         keeps the send-to-a-handle flow quick on the client side.
    mapping(bytes32 => address) internal _handleOwner;

    event ProfileCreated(
        address indexed owner, string handle, AccountKind accountKind, uint256 timestamp
    );
    event KycTierUpdated(address indexed owner, KycTier kycTier, uint256 timestamp);
    event HandleChanged(
        address indexed owner, string previousHandle, string newHandle, uint256 timestamp
    );

    constructor(IProtocolAuthority protocol_) {
        if (address(protocol_) == address(0)) revert ZeroAddress();
        protocol = protocol_;
    }

    // ── Accounts ─────────────────────────────────────────────────────────────

    /// @notice Opens an account for the caller and reserves its `.mansafi`
    ///         handle. New records begin at {KycTier.Unverified}; the compliance
    ///         authority raises the tier once verification clears off-chain.
    /// @param handle Lowercase, no at-sign, no `.mansafi` suffix.
    /// @param accountKind Personal, business, or an operator of agents.
    function createProfile(string calldata handle, AccountKind accountKind) external {
        if (_profiles[msg.sender].exists) revert ProfileAlreadyExists();

        uint256 len = bytes(handle).length;
        if (len == 0 || len > MAX_HANDLE_LEN) revert InvalidHandleLength();
        if (!_isValidHandle(handle)) revert InvalidHandleCharacters();

        bytes32 key = keccak256(bytes(handle));
        if (_handleOwner[key] != address(0)) revert HandleAlreadyTaken();

        _handleOwner[key] = msg.sender;
        _profiles[msg.sender] = Profile({
            owner: msg.sender,
            handle: handle,
            kycTier: KycTier.Unverified,
            accountKind: accountKind,
            createdAt: uint64(block.timestamp),
            updatedAt: uint64(block.timestamp),
            exists: true
        });

        emit ProfileCreated(msg.sender, handle, accountKind, block.timestamp);
    }

    /// @notice Moves the caller onto a different `.mansafi` handle and returns
    ///         the old one to the pool.
    /// @dev Only the name changes. Tier, kind, and creation time ride through
    ///      untouched, and the wallet address behind the record never moves at
    ///      all. Anything caching the previous resolution should re-resolve,
    ///      which is precisely what {HandleChanged} exists to tell an indexer.
    /// @param newHandle Lowercase, no at-sign, no suffix, same rules as opening.
    function changeHandle(string calldata newHandle) external {
        Profile storage p = _profiles[msg.sender];
        if (!p.exists) revert ProfileNotFound();

        uint256 len = bytes(newHandle).length;
        if (len == 0 || len > MAX_HANDLE_LEN) revert InvalidHandleLength();
        if (!_isValidHandle(newHandle)) revert InvalidHandleCharacters();

        bytes32 newKey = keccak256(bytes(newHandle));
        // Catches a name someone else holds and a pointless re-claim of your own.
        if (_handleOwner[newKey] != address(0)) revert HandleAlreadyTaken();

        string memory previous = p.handle;
        delete _handleOwner[keccak256(bytes(previous))];
        _handleOwner[newKey] = msg.sender;
        p.handle = newHandle;
        p.updatedAt = uint64(block.timestamp);

        emit HandleChanged(msg.sender, previous, newHandle, block.timestamp);
    }

    /// @notice Writes the outcome of an off-chain identity check onto a record.
    /// @dev Restricted to the compliance authority named by the protocol
    ///      contract. It moves nothing and blocks nothing; it exists so limits
    ///      enforced elsewhere have a verified tier to read.
    function setKycTier(address owner, KycTier kycTier) external {
        if (msg.sender != protocol.complianceAuthority()) {
            revert UnauthorizedComplianceAuthority();
        }
        Profile storage p = _profiles[owner];
        if (!p.exists) revert ProfileNotFound();

        p.kycTier = kycTier;
        p.updatedAt = uint64(block.timestamp);
        emit KycTierUpdated(owner, kycTier, block.timestamp);
    }

    // ── Reads ────────────────────────────────────────────────────────────────

    /// @inheritdoc IAccountRegistry
    function isRegistered(address owner) external view returns (bool) {
        return _profiles[owner].exists;
    }

    /// @inheritdoc IAccountRegistry
    function handleOf(address owner) external view returns (string memory) {
        return _profiles[owner].handle;
    }

    /// @inheritdoc IAccountRegistry
    function kycTierOf(address owner) external view returns (KycTier) {
        return _profiles[owner].kycTier;
    }

    /// @notice The complete record behind a wallet.
    function profileOf(address owner) external view returns (Profile memory) {
        return _profiles[owner];
    }

    /// @notice The record behind a `.mansafi` handle, in one read. The
    ///         send-to-a-handle flow resolves the name and then wants the kind
    ///         and tier to draw the confirmation card, and doing both here saves
    ///         a round trip on every recipient lookup. Unclaimed names return an
    ///         empty record with `exists` false.
    function profileByHandle(string calldata handle) external view returns (Profile memory) {
        return _profiles[_handleOwner[keccak256(bytes(handle))]];
    }

    /// @notice Points a `.mansafi` handle at its wallet, or at the zero address
    ///         when nobody has claimed it.
    function resolveHandle(string calldata handle) external view returns (address) {
        return _handleOwner[keccak256(bytes(handle))];
    }

    /// @notice Whether `handle` could be claimed right now: well-formed, inside
    ///         the length limit, and held by nobody. This is the question the
    ///         sign-up screen asks on every keystroke, and answering it here
    ///         means the client never has to carry its own copy of the rules.
    function handleAvailable(string calldata handle) external view returns (bool) {
        uint256 len = bytes(handle).length;
        if (len == 0 || len > MAX_HANDLE_LEN) return false;
        if (!_isValidHandle(handle)) return false;
        return _handleOwner[keccak256(bytes(handle))] == address(0);
    }

    /// @notice The handle as a person reads it, for instance `gwen.mansafi`.
    function fullHandle(address owner) external view returns (string memory) {
        return string.concat(_profiles[owner].handle, HANDLE_SUFFIX);
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    /// @dev Lowercase letters, digits, and underscores only. The restriction
    ///      exists so a handle survives being pasted into a request link or
    ///      packed into a QR payload without escaping or normalisation.
    function _isValidHandle(string calldata handle) internal pure returns (bool) {
        bytes memory b = bytes(handle);
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= 0x61 && c <= 0x7a) // a-z
                || (c >= 0x30 && c <= 0x39) // 0-9
                || c == 0x5f; // _
            if (!ok) return false;
        }
        return true;
    }
}
