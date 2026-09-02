// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IProtocolAuthority} from "./interfaces/IProtocolAuthority.sol";
import "./libraries/ProtocolErrors.sol";

/// @title ProtocolAuthority
/// @notice The protocol's control panel on Robinhood Chain: who administers it,
///         who may attest identity, whether value is allowed to move, and where
///         fees are routed. It is a coordination point and nothing more.
///
/// @dev Worth being explicit about what this contract cannot do, because the
///      name invites the opposite assumption. It holds no balances. Account
///      assets sit in the accounts' own wallets, and the only pooled funds
///      anywhere in the protocol are agent vaults, each scoped to one agent
///      inside {AgentController}. The admin key here can pause the protocol and
///      point modules at different authorities; it cannot spend anything.
///
///      The admin role is expected to graduate onto a Safe multisig after beta.
///      That migration is a call to {updateConfig} or a two-step handoff, not a
///      redeployment of everything that reads this contract.
contract ProtocolAuthority is IProtocolAuthority {
    /// @notice Thrown when someone other than the nominated successor tries to
    ///         complete an authority handoff.
    error NotPendingAuthority();

    /// @notice Holder of the admin role: rotates authorities, works the pause,
    ///         and configures fee routing.
    address public authority;

    /// @notice Successor nominated by the current authority. It holds no power
    ///         until it calls {acceptAuthority}, which is what stops a mistyped
    ///         address from silently becoming the protocol's administrator.
    address public pendingAuthority;

    /// @notice The address permitted to record KYC outcomes against accounts.
    ///         Stands in for the off-chain verification vendor (Persona, Onfido,
    ///         or similar) writing back the result of a completed check.
    address public complianceAuthority;

    /// @notice Circuit breaker. While set, calls that move value are refused
    ///         protocol-wide, but identity and agent configuration stay live.
    ///         That asymmetry is intentional: an operator in the middle of an
    ///         incident needs to keep pausing and revoking agents.
    bool public paused;

    /// @notice Where protocol fees land. While this is the zero address no fee
    ///         is charged anywhere, which is the state the protocol ships in.
    address public treasury;

    /// @notice The $MANSA-aware fee schedule that settlement contracts quote
    ///         against. Zero disables fees. Held as a plain address; consumers
    ///         cast to IFeeSchedule at the point of use.
    address public feeSchedule;

    event ConfigInitialized(address indexed authority, address indexed complianceAuthority);
    event ConfigAuthorityUpdated(address indexed authority, address indexed complianceAuthority);
    event AuthorityTransferStarted(
        address indexed currentAuthority, address indexed pendingAuthority
    );
    event AuthorityTransferAccepted(
        address indexed previousAuthority, address indexed newAuthority
    );
    event ProtocolPauseToggled(bool paused);
    event FeeConfigUpdated(address indexed treasury, address indexed feeSchedule);

    modifier onlyAuthority() {
        if (msg.sender != authority) revert Unauthorized();
        _;
    }

    /// @param complianceAuthority_ Address that will attest KYC outcomes.
    constructor(address complianceAuthority_) {
        if (complianceAuthority_ == address(0)) revert ZeroAddress();
        authority = msg.sender;
        complianceAuthority = complianceAuthority_;
        emit ConfigInitialized(msg.sender, complianceAuthority_);
    }

    /// @notice Replaces the admin authority and the compliance authority in one
    ///         call.
    /// @dev The direct path, reserved to the sitting authority. Useful for
    ///      moving administration onto a multisig or swapping the identity
    ///      vendor without redeploying any module.
    function updateConfig(address newAuthority, address newComplianceAuthority)
        external
        onlyAuthority
    {
        if (newAuthority == address(0) || newComplianceAuthority == address(0)) {
            revert ZeroAddress();
        }
        authority = newAuthority;
        complianceAuthority = newComplianceAuthority;
        // An outright replacement overrides whatever handoff was in flight.
        pendingAuthority = address(0);
        emit ConfigAuthorityUpdated(newAuthority, newComplianceAuthority);
    }

    /// @notice Nominates a successor without surrendering anything yet. The
    ///         nominee becomes authority only by calling {acceptAuthority}.
    /// @dev The careful path. Requiring the recipient to sign for the role rules
    ///      out the failure a one-step transfer invites, where a typo hands the
    ///      pause-and-rotate key to an address nobody controls. Nominating the
    ///      zero address withdraws an outstanding nomination.
    function beginAuthorityTransfer(address newAuthority) external onlyAuthority {
        pendingAuthority = newAuthority;
        emit AuthorityTransferStarted(authority, newAuthority);
    }

    /// @notice Claims the role nominated through {beginAuthorityTransfer}.
    ///         Nobody but the nominee can call it.
    function acceptAuthority() external {
        if (msg.sender != pendingAuthority) revert NotPendingAuthority();
        address previous = authority;
        authority = msg.sender;
        pendingAuthority = address(0);
        emit AuthorityTransferAccepted(previous, msg.sender);
    }

    /// @notice Opens or closes the protocol-wide circuit breaker.
    function setPause(bool paused_) external onlyAuthority {
        paused = paused_;
        emit ProtocolPauseToggled(paused_);
    }

    /// @notice Configures, or dismantles, fee routing. Fees require both a
    ///         destination and a schedule; clear either one and charging stops
    ///         everywhere at once. Every module reads this pair to decide
    ///         whether it owes a fee and how large it is.
    /// @param treasury_ Fee destination, or zero to stop charging.
    /// @param feeSchedule_ IFeeSchedule pricing fees and $MANSA discounts, or
    ///        zero to stop charging.
    function setFeeConfig(address treasury_, address feeSchedule_) external onlyAuthority {
        treasury = treasury_;
        feeSchedule = feeSchedule_;
        emit FeeConfigUpdated(treasury_, feeSchedule_);
    }
}
