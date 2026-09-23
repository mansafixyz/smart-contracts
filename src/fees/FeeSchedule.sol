// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IFeeSchedule} from "./IFeeSchedule.sol";
import {StakingVault} from "./StakingVault.sol";
import "../libraries/ProtocolErrors.sol";

/// @title FeeSchedule
/// @notice The protocol's price list, and the home of the $MANSA discount.
///         Contracts that move value call {quoteFee} to price a transfer; the
///         app and SDK call the neighbouring views to show someone their live
///         rate. Both arrive at the same number by the same route.
///
/// @dev All arithmetic in basis points, where 1 bps is 0.01%:
///
///        grossFee   = amount * baseFeeBps / 10_000
///        discount   = discountBpsOf(payer)          // from held + staked $MANSA
///        netFee     = grossFee * (10_000 - discount) / 10_000
///        feeAmount  = min(netFee, feeCap)           // when a cap is configured
///
///      The discount derives from a loyalty weight: staked $MANSA at full
///      weight, plus held $MANSA at `heldWeightBps` of that. The weight is read
///      against an ascending table and the account takes the discount of the
///      highest threshold it clears. Staking therefore beats holding and holding
///      beats neither, which is the whole point of the curve.
///
///      Amounts and the cap are in the settlement token's smallest unit, with
///      defaults assuming a six-decimal stablecoin: 0.10% capped at 5 USDG.
///      Weight thresholds are in $MANSA's own smallest unit, at 18 decimals.
contract FeeSchedule is IFeeSchedule {
    /// @notice Thrown when someone other than the nominated successor tries to
    ///         complete an authority handoff.
    error NotPendingAuthority();

    struct Tier {
        uint256 minWeight; // loyalty weight required, in $MANSA units (18 dp)
        uint16 discountBps; // what clearing it takes off the base rate
    }

    uint256 internal constant BPS = 10_000;

    /// @notice Who may retune the schedule; the protocol multisig in practice.
    address public authority;

    /// @notice Successor nominated for that role, powerless until it calls
    ///         {acceptAuthority}. The key that prices every fee in the protocol
    ///         should not be losable to a typo.
    address public pendingAuthority;

    /// @notice The $MANSA token whose wallet balance feeds the loyalty weight.
    IERC20 public immutable mansa;

    /// @notice The vault whose staked balance feeds the loyalty weight.
    StakingVault public immutable staking;

    /// @notice The rate applied before any discount, in basis points.
    uint16 public baseFeeBps;

    /// @notice Hard ceiling on a single fee, in settlement-token units. Zero
    ///         means no ceiling.
    uint256 public feeCap;

    /// @notice What merely-held $MANSA is worth, as basis points of full weight.
    ///         Staked $MANSA is always worth full weight.
    uint16 public heldWeightBps;

    /// @notice The discount curve, ascending by `minWeight`.
    Tier[] public tiers;

    event FeeScheduleUpdated(uint16 baseFeeBps, uint256 feeCap, uint16 heldWeightBps);
    event TiersUpdated(uint256 count);
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

    constructor(address authority_, IERC20 mansa_, StakingVault staking_) {
        if (
            authority_ == address(0) || address(mansa_) == address(0)
                || address(staking_) == address(0)
        ) {
            revert ZeroAddress();
        }
        authority = authority_;
        mansa = mansa_;
        staking = staking_;

        // Shipping defaults: a tenth of a percent, never more than 5 units
        // (5 USDG at six decimals), and held tokens worth half a staked one.
        baseFeeBps = 10;
        feeCap = 5_000_000;
        heldWeightBps = 5_000;

        // The published curve, thresholds in whole $MANSA at 18 decimals.
        tiers.push(Tier(1_000e18, 1_000)); // 1k and up:   10% off
        tiers.push(Tier(10_000e18, 2_500)); // 10k and up:  25% off
        tiers.push(Tier(100_000e18, 5_000)); // 100k and up: 50% off
        tiers.push(Tier(1_000_000e18, 7_500)); // 1M and up:   75% off
    }

    // ── Pricing ──────────────────────────────────────────────────────────────

    /// @inheritdoc IFeeSchedule
    function quoteFee(address payer, uint256 amount)
        external
        view
        returns (uint256 feeAmount, uint256 effectiveBps)
    {
        (feeAmount, effectiveBps,) = _quote(payer, amount);
    }

    /// @inheritdoc IFeeSchedule
    function discountBpsOf(address account) public view returns (uint256) {
        uint256 weight = loyaltyWeightOf(account);
        uint256 discount;
        uint256 n = tiers.length;
        for (uint256 i; i < n; ++i) {
            Tier storage t = tiers[i];
            if (weight >= t.minWeight) {
                discount = t.discountBps;
            } else {
                break; // ascending table: nothing later can match either
            }
        }
        return discount;
    }

    /// @inheritdoc IFeeSchedule
    function loyaltyWeightOf(address account) public view returns (uint256) {
        uint256 staked = staking.stakedOf(account);
        uint256 held = mansa.balanceOf(account);
        return staked + (held * heldWeightBps) / BPS;
    }

    /// @notice Discount and resulting quote together, for interfaces that want
    ///         to show both.
    function feePreview(address payer, uint256 amount)
        external
        view
        returns (uint256 discountBps, uint256 feeAmount, uint256 effectiveBps)
    {
        (feeAmount, effectiveBps, discountBps) = _quote(payer, amount);
    }

    /// @dev The formula lives here once. What settlement contracts charge
    ///      ({quoteFee}) and what an interface displays ({feePreview}) both come
    ///      through this function, which is what guarantees the quoted rate and
    ///      the charged rate cannot drift apart.
    function _quote(address payer, uint256 amount)
        internal
        view
        returns (uint256 feeAmount, uint256 effectiveBps, uint256 discountBps)
    {
        discountBps = discountBpsOf(payer);
        uint256 gross = (amount * baseFeeBps) / BPS;
        uint256 net = (gross * (BPS - discountBps)) / BPS;
        feeAmount = (feeCap != 0 && net > feeCap) ? feeCap : net;
        effectiveBps = amount == 0 ? 0 : (feeAmount * BPS) / amount;
    }

    // ── Tuning ───────────────────────────────────────────────────────────────

    /// @notice Resets the base rate, the ceiling, and what held tokens are worth.
    function setSchedule(uint16 baseFeeBps_, uint256 feeCap_, uint16 heldWeightBps_)
        external
        onlyAuthority
    {
        if (baseFeeBps_ > BPS || heldWeightBps_ > BPS) revert InvalidFeeConfig();
        baseFeeBps = baseFeeBps_;
        feeCap = feeCap_;
        heldWeightBps = heldWeightBps_;
        emit FeeScheduleUpdated(baseFeeBps_, feeCap_, heldWeightBps_);
    }

    /// @notice Swaps in a new discount curve. Thresholds must strictly ascend
    ///         and no single tier may discount more than the whole fee.
    function setTiers(Tier[] calldata newTiers) external onlyAuthority {
        uint256 n = newTiers.length;
        for (uint256 i; i < n; ++i) {
            if (newTiers[i].discountBps > BPS) revert InvalidFeeConfig();
            if (i > 0 && newTiers[i].minWeight <= newTiers[i - 1].minWeight) {
                revert InvalidFeeConfig();
            }
        }
        delete tiers;
        for (uint256 i; i < n; ++i) {
            tiers.push(newTiers[i]);
        }
        emit TiersUpdated(n);
    }

    /// @notice Nominates the next tuning authority without giving anything up
    ///         yet. The nominee takes the role by calling {acceptAuthority}.
    /// @dev The same two-step handoff every admin role in the protocol uses, so
    ///      there is one procedure to learn rather than three. Nominating the
    ///      zero address withdraws an outstanding nomination.
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

    /// @notice How many tiers the current curve has.
    function tierCount() external view returns (uint256) {
        return tiers.length;
    }

    /// @notice The whole discount curve in one read, ascending by weight. An
    ///         interface drawing the tier ladder wants all of it at once rather
    ///         than one `tiers(i)` call per rung.
    function getTiers() external view returns (Tier[] memory) {
        return tiers;
    }
}
