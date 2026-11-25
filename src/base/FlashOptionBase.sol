// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IManicFlashOptionErrors} from "../interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents} from "../interfaces/IManicFlashOptionEvents.sol";
import {IManicFlashOptionRoles} from "../interfaces/IManicFlashOptionRoles.sol";
import {BreakerLib} from "../libraries/BreakerLib.sol";
import {LeverageMath} from "../libraries/LeverageMath.sol";
import {OrderLib} from "../libraries/OrderLib.sol";
import {OpenOrder, SellOrder} from "../types/OrderTypes.sol";
import {Breaker, Market, PoolState, Position, Status} from "../types/StorageTypes.sol";
import {FlashOptionStorage} from "./FlashOptionStorage.sol";

/// @title FlashOptionBase
/// @author Manic
/// @notice The shared base under every module: the OpenZeppelin bases, the role ids, and the internal helpers that
///         more than one function needs.
/// @dev The OpenZeppelin bases each keep their state in an ERC-7201 namespace of their own, so their order here never
///      moves storage. It does fix the order in which `initialize` must call their initializers, so it never changes:
///      - `UUPSUpgradeable`: the upgrade function, gated by `ManicFlashOption._authorizeUpgrade`. Stateless in
///        OpenZeppelin 5.6.1, with no initializer;
///      - `AccessControlDefaultAdminRulesUpgradeable`: roles, with exactly one default admin, transferred in two steps
///        after a delay;
///      - `EIP712Upgradeable`: the signing domain for the users' orders;
///      - `ReentrancyGuardTransient`: `nonReentrant` on every state-changing function of the modules. Stateless: it
///        uses a transient slot, so it is safe behind a proxy.
///      Our interfaces come first in the parent list, in the order `IManicFlashOption` uses
///      (docs/ARCHITECTURE.md §3.2).
///      There is no state here: all storage is the `Layout` of `FlashOptionStorage`.
/// @custom:security-contact See SECURITY.md
abstract contract FlashOptionBase is
    IManicFlashOptionEvents,
    IManicFlashOptionErrors,
    IManicFlashOptionRoles,
    Initializable,
    UUPSUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuardTransient,
    FlashOptionStorage
{
    using SafeERC20 for IERC20;
    using BreakerLib for Breaker;

    // ---------------------------------------------------------------------------------------------------------------
    // Roles (docs/ARCHITECTURE.md §4.2). Every role's admin is DEFAULT_ADMIN_ROLE, OpenZeppelin's default.
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IManicFlashOptionRoles
    bytes32 public constant override UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @inheritdoc IManicFlashOptionRoles
    bytes32 public constant override OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @inheritdoc IManicFlashOptionRoles
    bytes32 public constant override GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @inheritdoc IManicFlashOptionRoles
    bytes32 public constant override OPENER_ROLE = keccak256("OPENER_ROLE");

    /// @inheritdoc IManicFlashOptionRoles
    bytes32 public constant override SETTLER_ROLE = keccak256("SETTLER_ROLE");

    // ---------------------------------------------------------------------------------------------------------------
    // Limits on the settings (docs/ARCHITECTURE.md §6.8, §8.1)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The lowest pool floor, in whole tokens (× 10^decimals).
    uint64 private constant _MIN_POOL_FLOOR_TOKENS = 500;

    /// @notice The shortest safety refund delay after a position's expiry. 0 switches the refund off.
    uint48 private constant _MIN_REFUND_DELAY_SECS = 1 hours;

    /// @notice The shortest circuit-breaker window.
    uint32 private constant _MIN_BREAKER_WINDOW_SECS = 60;

    /// @notice The longest circuit-breaker window: one day.
    uint32 private constant _MAX_BREAKER_WINDOW_SECS = 86_400;

    /// @notice The least gas a payout must have before it tries its transfer (docs/ARCHITECTURE.md §8.8).
    /// @dev A lower bound only: it is never forwarded as a fixed amount, so a change in gas prices can't break a
    ///      payout. It must stay above the token's most expensive transfer. `MockUSDG`, which copies USDG's logic,
    ///      uses 36,781 gas to pay a new holder with every slot cold, and USDG's proxy adds about 5,000. The fork tests
    ///      check that the real USDG on Robinhood Chain pays a new holder for less than this
    ///      (test/fork/RealUsdg.t.sol).
    uint256 private constant _MIN_PAY_GAS = 60_000;

    /// @notice A payout transfer that fails and leaves no more than 1/16 of the gas `_pay` started with ran out of
    ///         gas, rather than being refused (docs/ARCHITECTURE.md §8.8).
    /// @dev Each call keeps back 1/64 of the gas it passes on (EIP-150) and gets it back when the call below it fails,
    ///      so a transfer that runs out of gas k calls deep leaves about k/64. 1/16 covers up to three levels: the
    ///      token, a proxy in front of it (USDG has one) and one call the token makes. A refusal costs a few thousand
    ///      gas and leaves far more behind.
    uint256 private constant _OUT_OF_GAS_DIVISOR = 16;

    // ---------------------------------------------------------------------------------------------------------------
    // Settings shared by `initialize` and the admin setters. Each checks its value, writes it and emits the
    // setter's event, so the first value and every later change look the same to an indexer.
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Sets the pool floor: free money below which no loser fee is taken and no withdrawal may go.
    /// @dev Reverts `InvalidLeverageParams` below 500 whole tokens. Reads `tokenDecimals`, so the token must be set
    ///      first. With at most 9 decimals the bound is at most 5 × 10^11, far inside `uint64`. Emits
    ///      {PoolFloorUpdated}.
    /// @param poolFloor The new floor, in base units of the token.
    function _setPoolFloor(uint64 poolFloor) internal {
        Layout storage $ = _getFlashOptionStorage();
        if (poolFloor < _MIN_POOL_FLOOR_TOKENS * 10 ** $.tokenDecimals) revert InvalidLeverageParams();
        $.pool.poolFloor = poolFloor;
        emit PoolFloorUpdated(poolFloor);
    }

    /// @notice Sets where swept fees and seed recovery go, and where rewards withdrawals go.
    /// @dev Reverts `ZeroAddress` if either is unset. Emits {RecipientsUpdated}.
    /// @param feeRecipient Receives swept fees and seed recovery.
    /// @param rewardsRecipient Receives rewards withdrawals.
    function _setRecipients(address feeRecipient, address rewardsRecipient) internal {
        if (feeRecipient == address(0) || rewardsRecipient == address(0)) revert ZeroAddress();
        Layout storage $ = _getFlashOptionStorage();
        $.feeRecipient = feeRecipient;
        $.rewardsRecipient = rewardsRecipient;
        emit RecipientsUpdated(feeRecipient, rewardsRecipient);
    }

    /// @notice Sets how long after its expiry anyone may refund a position that was never ended.
    /// @dev Reverts `InvalidRefundDelay` unless 0 (off) or at least 1 hour. Emits {RefundDelayUpdated}.
    /// @param refundDelaySecs The delay, in seconds.
    function _setRefundDelay(uint48 refundDelaySecs) internal {
        if (refundDelaySecs != 0 && refundDelaySecs < _MIN_REFUND_DELAY_SECS) revert InvalidRefundDelay();
        _getFlashOptionStorage().refundDelaySecs = refundDelaySecs;
        emit RefundDelayUpdated(refundDelaySecs);
    }

    /// @notice Sets the payout circuit breaker's limit and window (docs/ARCHITECTURE.md §8.11).
    /// @dev Reverts `InvalidBreakerParams` unless the window is 60 to 86,400 seconds; a limit of 0 switches the
    ///      breaker off. It leaves the counters and the window start alone. Emits {CircuitBreakerUpdated}.
    /// @param maxNetProfit The net profit allowed out per window, in base units.
    /// @param windowSecs The window's length, in seconds.
    function _setBreaker(uint64 maxNetProfit, uint32 windowSecs) internal {
        if (windowSecs < _MIN_BREAKER_WINDOW_SECS || windowSecs > _MAX_BREAKER_WINDOW_SECS) {
            revert InvalidBreakerParams();
        }
        Layout storage $ = _getFlashOptionStorage();
        $.breaker.maxNetProfit = maxNetProfit;
        $.breaker.windowSecs = windowSecs;
        emit CircuitBreakerUpdated(maxNetProfit, windowSecs);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Payouts (docs/ARCHITECTURE.md §8.8)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Pays `amount` to `to` if the token lets it, and otherwise keeps it for `to` to claim later. Settle,
    ///         sell, repay and refund pay users through this, so a frozen or blocklisted winner can never block a
    ///         batch or the repay queue.
    /// @dev Three cases:
    ///      - the transfer succeeds: paid;
    ///      - the token refuses (it reverts or returns false, as USDG does for a frozen recipient or while paused):
    ///        the amount is added to `claimable[to]` and `totalClaimable`, and {PayoutDeferred} is emitted;
    ///      - the transfer ran out of gas: the whole transaction reverts (`InsufficientGasForPayout`).
    ///      The last case stops a relayer from starving a call on purpose to push an honest winner into `claimable`.
    ///      There are two guards. The payout needs `_MIN_PAY_GAS` before it starts, more than a USDG transfer uses.
    ///      And if the transfer fails leaving no more than 1/16 of the gas the payout started with
    ///      (`_OUT_OF_GAS_DIVISOR`), it used up the gas it was given, so it ran out of gas rather than being refused:
    ///      a token that refuses does so quickly. `trySafeTransfer` reads at most 32 bytes of the token's reply, so a
    ///      huge reply can't burn the gas left.
    /// @param to The recipient.
    /// @param amount The amount, in base units. Zero does nothing.
    /// @param positionId The position the payout is for, named in {PayoutDeferred}.
    function _pay(address to, uint64 amount, bytes32 positionId) internal {
        if (amount == 0) return;
        uint256 gasBefore = gasleft();
        if (gasBefore < _MIN_PAY_GAS) revert InsufficientGasForPayout();
        Layout storage $ = _getFlashOptionStorage();
        if ($.token.trySafeTransfer(to, amount)) return;
        if (gasleft() <= gasBefore / _OUT_OF_GAS_DIVISOR) revert InsufficientGasForPayout();
        $.claimable[to] = _add64($.claimable[to], amount);
        $.pool.totalClaimable = _add64($.pool.totalClaimable, amount);
        emit PayoutDeferred(positionId, to, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Ending positions (docs/ARCHITECTURE.md §8.3 to §8.6). Every ending (liquidate, settle, sell, the safety refund
    // and repay) changes the books through these.
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Releases an ending position's hold on the pool: its stake leaves the held margin, its max profit
    ///         leaves the open exposure, and the open count drops by one.
    /// @dev The total doesn't change here: each ending takes out of it what leaves the pool. The max profit is
    ///      recomputed from the stored stake and cap, which are the values `open` added, so the open exposure goes
    ///      back exactly.
    /// @param pool The pool's books.
    /// @param stake The position's stake.
    /// @param capBps The position's payout cap.
    function _releaseMargin(PoolState storage pool, uint64 stake, uint16 capBps) internal {
        // can't underflow: the three are sums over the open positions, and this one is open
        pool.lockedMargin -= stake;
        pool.openMaxProfit -= LeverageMath.maxProfit(stake, capBps);
        pool.openPositions -= 1;
    }

    /// @notice Closes a position for good: `Closed`, with slot 0 kept as the tombstone, so its id can never be opened
    ///         again, and slot 1 cleared, for a gas refund.
    /// @dev Slot 2 is left alone: it is only ever written for an IOU, which repay closes.
    /// @param p The position's storage.
    function _closePosition(Position storage p) internal {
        p.status = Status.Closed;
        p.stake = 0;
        p.entryPrice = 0;
        p.liqPrice = 0;
        p.floorBps = 0;
        p.capBps = 0;
        p.leverage = 0;
    }

    /// @notice Adds a batch's fees to the pending fees, which anyone sweeps to the fee recipient (`sweepFees`), and to
    ///         the cumulative `feesPaid`.
    /// @dev Called once per call, after the loop (`MathOverflow` on overflow).
    /// @param fees The fees taken out of the pool's total by this call.
    function _accrueFees(uint64 fees) internal {
        PoolState storage pool = _getFlashOptionStorage().pool;
        pool.feesPending = _add64(pool.feesPending, fees);
        pool.feesPaid = _add64(pool.feesPaid, fees);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The payout circuit breaker (docs/ARCHITECTURE.md §8.11)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Counts one call's winnings and losses in the payout circuit breaker, and announces a trip.
    ///         `settle`, `liquidate`, `sell` and `repay` call it once, after their endings.
    /// @dev The amounts are the users' winnings and losses before fees: the profit a call paid out (a settle's profit
    ///      paid now, a sale's profit, a repayment), and the stakes the pool kept (a settle's or a sale's loss, a
    ///      liquidated stake). The window and the trip are `BreakerLib.count`'s. A trip emits
    ///      {CircuitBreakerTripped}, once, after the call's own events. It blocks only `open` and `sell` (§8.10): the
    ///      call that trips it completes, and its winners are paid.
    /// @param profit The profit the call paid to users, before fees.
    /// @param loss The users' losses the call kept in the pool, before fees.
    function _countForBreaker(uint64 profit, uint64 loss) internal {
        Breaker storage b = _getFlashOptionStorage().breaker;
        if (b.count(profit, loss, _now48())) emit CircuitBreakerTripped(b.profitOut, b.lossIn, b.windowStart);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Signed orders (docs/ARCHITECTURE.md §7)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The EIP-712 digest a user signs to open a position.
    /// @dev The order's struct hash (`OrderLib.hashStruct`) under this contract's domain: the name
    ///      "Manic Flash Option", version "1", the chain id and this proxy's address. A signature made for another
    ///      chain or another deployment never matches it.
    /// @param o The order.
    /// @return The digest.
    function _openOrderDigest(OpenOrder calldata o) internal view returns (bytes32) {
        return _hashTypedDataV4(OrderLib.hashStruct(o));
    }

    /// @notice The EIP-712 digest a position's user signs to sell it early.
    /// @dev The same as `_openOrderDigest`, for a `SellOrder`.
    /// @param s The order.
    /// @return The digest.
    function _sellOrderDigest(SellOrder calldata s) internal view returns (bytes32) {
        return _hashTypedDataV4(OrderLib.hashStruct(s));
    }

    /// @notice Reverts `InvalidSignature` unless `signature` is `signer`'s signature of `digest`.
    /// @dev Two ways to pass, in this order (security checklist SIG-6):
    ///      1. ECDSA: the signature recovers to `signer`. `tryRecoverCalldata` refuses a malleable (high) `s`, a `v`
    ///         other than 27 or 28, any length but 65 bytes, and a signature that recovers to no address, so a zero
    ///         `signer` can never pass this way.
    ///      2. Only if that fails, ERC-1271: `signer` is a contract whose `isValidSignature(digest, signature)`
    ///         returns the magic value. OpenZeppelin reads at most 32 bytes of the reply. An address without code
    ///         can't answer, so it fails here, and the contract never asks whether `signer` has code
    ///         (ARCHITECTURE §15 rule 13).
    ///      ECDSA goes first, so an EOA that later gets EIP-7702 code still verifies with its own key. OpenZeppelin's
    ///      `SignatureChecker.isValidSignatureNow` is not used: since 5.1 it skips ECDSA for any address with code.
    /// @param signer Who must have signed: the order's user, or the position's user for a sale.
    /// @param digest The EIP-712 digest that was signed.
    /// @param signature 65 bytes (`r`, `s`, `v`) from an EOA, or whatever a contract wallet expects.
    function _checkSignature(address signer, bytes32 digest, bytes calldata signature) internal view {
        // The third value only details a failure; every failure ends in `InvalidSignature` (audit/static-analysis.md).
        // slither-disable-next-line unused-return
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) return;
        if (SignatureChecker.isValidERC1271SignatureNowCalldata(signer, digest, signature)) return;
        revert InvalidSignature();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Lookups shared by the modules
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Finds a market by its price feed and its leverage: one feed has a market per leverage (ADR 0008).
    /// @dev Reverts `UnknownMarket` if no market has the pair. `marketIndexPlusOne` stores index + 1 under the pair's
    ///      key, so 0 means "none".
    /// @param marketId The market's Pyth feed id.
    /// @param leverage The market's leverage.
    /// @return m The market's storage.
    /// @return index Its index in `Layout.markets`, which positions record.
    function _market(bytes32 marketId, uint16 leverage) internal view returns (Market storage m, uint16 index) {
        Layout storage $ = _getFlashOptionStorage();
        uint16 indexPlusOne = $.marketIndexPlusOne[_marketKey(marketId, leverage)];
        if (indexPlusOne == 0) revert UnknownMarket();
        index = indexPlusOne - 1;
        m = $.markets[index];
    }

    /// @notice The chain's clock as the 48-bit time the books store.
    /// @return `block.timestamp`. 48 bits of seconds last about 8.9 million years, so it never truncates.
    function _now48() internal view returns (uint48) {
        // casting to uint48 is safe: block.timestamp stays below 2^48 for millions of years
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(block.timestamp);
    }

    /// @notice The key a market is filed under in `marketIndexPlusOne`: `keccak256(abi.encode(marketId, leverage))`.
    /// @dev A hash of the pair, so the mapping keeps its type and storage keeps its layout (ADR 0008). `abi.encode`
    ///      pads each value to 32 bytes, so no two pairs share a key.
    /// @param marketId The market's Pyth feed id.
    /// @param leverage The market's leverage.
    /// @return The market's key.
    function _marketKey(bytes32 marketId, uint16 leverage) internal pure returns (bytes32) {
        return keccak256(abi.encode(marketId, leverage));
    }

    /// @notice `a + b`, reverting `MathOverflow` when the sum doesn't fit 64 bits.
    /// @param a The first amount.
    /// @param b The second amount.
    /// @return The sum.
    function _add64(uint64 a, uint64 b) internal pure returns (uint64) {
        uint256 sum = uint256(a) + b;
        if (sum > type(uint64).max) revert MathOverflow();
        // casting to uint64 is safe because the sum was just checked to fit
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(sum);
    }
}
