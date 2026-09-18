// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAccountRegistry} from "./interfaces/IAccountRegistry.sol";
import "./libraries/ProtocolErrors.sol";

/// @title DisclosureLog
/// @notice A thin, permanent record that a disclosure happened.
///
/// @dev Confidential transfers hide amounts from the public. They do not hide
///      them from the two parties, and they do not hide them from an auditor the
///      account holder decides to show. The proof that reveals a decrypted
///      amount is built on the client against the view key and never comes near
///      this contract. What gets written here is only the durable, timestamped
///      claim that "this account produced a disclosure for this transaction,
///      addressed to this viewer" — which is what an audit export needs in order
///      to demonstrate cooperation with a request, without publishing either the
///      counterparty or the proof to everyone else.
contract DisclosureLog {
    struct DisclosureReceipt {
        address profile;
        string txReference; // the confidential transfer this disclosure covers
        bytes32 viewerHash; // who it went to, hashed rather than named
        bytes32 disclosureCommitment; // hash of the payload, for off-chain matching
        uint64 filedAt;
        bool exists;
    }

    uint256 internal constant MAX_TX_REFERENCE_LEN = 88;

    IAccountRegistry public immutable registry;

    uint256 public receiptCount;
    mapping(uint256 => DisclosureReceipt) internal _receipts;

    /// @notice Receipt ids per account, in the order they were filed. An export
    ///         walks this list rather than replaying the entire event log.
    mapping(address => uint256[]) internal _receiptsByProfile;

    event DisclosureFiled(
        uint256 indexed receiptId, address indexed profile, string txReference, uint256 timestamp
    );

    constructor(IAccountRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    /// @notice Records that a disclosure proof was generated for a confidential
    ///         transfer and handed to a counterparty. The proof stays off-chain
    ///         in its entirety; this call only fixes the fact and the moment.
    /// @param txReference Identifies the transfer being disclosed.
    /// @param viewerHash Hashed identity of the recipient, so the receipt cannot
    ///        be mined for who an account has been dealing with.
    /// @param disclosureCommitment Hash of the payload, letting the recipient
    ///        check off-chain that what they hold is what was filed.
    function file(string calldata txReference, bytes32 viewerHash, bytes32 disclosureCommitment)
        external
        returns (uint256 receiptId)
    {
        if (!registry.isRegistered(msg.sender)) revert ProfileNotFound();
        uint256 len = bytes(txReference).length;
        if (len == 0 || len > MAX_TX_REFERENCE_LEN) revert InvalidTxReferenceLength();

        receiptId = ++receiptCount;
        _receipts[receiptId] = DisclosureReceipt({
            profile: msg.sender,
            txReference: txReference,
            viewerHash: viewerHash,
            disclosureCommitment: disclosureCommitment,
            filedAt: uint64(block.timestamp),
            exists: true
        });
        _receiptsByProfile[msg.sender].push(receiptId);

        emit DisclosureFiled(receiptId, msg.sender, txReference, block.timestamp);
    }

    function getReceipt(uint256 receiptId) external view returns (DisclosureReceipt memory) {
        return _receipts[receiptId];
    }

    /// @notice How many receipts an account has filed.
    function receiptCountOf(address profile) external view returns (uint256) {
        return _receiptsByProfile[profile].length;
    }

    /// @notice Every receipt id an account has filed, oldest first. Pair with
    ///         {getReceipt} to hydrate each one for an export.
    function receiptIdsOf(address profile) external view returns (uint256[] memory) {
        return _receiptsByProfile[profile];
    }

    /// @notice One page of an account's receipt ids, oldest first, beginning at
    ///         `offset` and running at most `limit` long. Years of disclosures
    ///         will outgrow what a single RPC response can carry, so a client
    ///         advances through this until a short page comes back.
    function receiptIdsOf(address profile, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory page)
    {
        uint256[] storage all = _receiptsByProfile[profile];
        uint256 total = all.length;
        if (offset >= total) return new uint256[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = all[i];
        }
    }
}
