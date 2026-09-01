// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// File-level custom errors shared across the protocol. Declaring them once,
// outside any contract, keeps every module reverting with the same selector for
// the same condition, which is what lets a client decode a failure without
// knowing which contract produced it. Custom errors are also cheaper to deploy
// and cheaper to hit than revert strings.

// ── Protocol-wide ───────────────────────────────────────────────────────────
error ZeroAddress();
error ProtocolPaused();
error Unauthorized();
error UnauthorizedComplianceAuthority();

// ── Accounts and handles ────────────────────────────────────────────────────
error InvalidHandleLength();
error InvalidHandleCharacters();
error HandleAlreadyTaken();
error ProfileAlreadyExists();
error ProfileNotFound();

// ── Agent lifecycle ─────────────────────────────────────────────────────────
error InvalidLabelLength();
error AgentNotActive();
error AgentAlreadyRevoked();
error UnauthorizedAgentOwner();
error UnauthorizedAgentSigner();

// ── Spend policy ────────────────────────────────────────────────────────────
error InvalidSpendAmount();
error PerTxLimitExceedsDailyLimit();
error PerTransactionLimitExceeded();
error DailyLimitExceeded();
error RecipientNotAllowed();
error TooManyAllowedRecipients();
error InvalidHitlThreshold();
error AmountExceedsHitlThreshold();
error AmountWithinHitlThreshold();
error TierRequiresApproval();
error InsufficientVaultBalance();

// ── Approval queue ──────────────────────────────────────────────────────────
error PendingApprovalNotFound();

// ── Requests to pay ─────────────────────────────────────────────────────────
error RequestNotOpen();
error RequestExpired();
error RequestAmountMismatch();
error RequestCommitmentMismatch();
error InvalidExpiry();

// ── Disclosure receipts ─────────────────────────────────────────────────────
error InvalidTxReferenceLength();

// ── Encrypted balances ──────────────────────────────────────────────────────
error AccountNotRegistered();
error AccountAlreadyRegistered();
error InvalidPublicKey();
error ProofRejected();

// ── Fees and staking ────────────────────────────────────────────────────────
error InvalidFeeConfig();
error InsufficientStakedBalance();
