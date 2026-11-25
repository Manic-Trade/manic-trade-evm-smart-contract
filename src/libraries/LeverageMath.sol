// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors} from "../interfaces/IManicFlashOptionErrors.sol";
import {RepaySplit, SellSplit, SettleSplit} from "../types/MathTypes.sol";
import {Side, WithdrawPurpose} from "../types/StorageTypes.sol";

/// @title LeverageMath
/// @author Manic
/// @notice The Flash Option's maths: a position's liquidation and cap lines, its payout multiple, the fees, the
///         money splits of a settle, a sale and a repayment, and the checks on price times, the open gate, sales and
///         withdrawals. Every function is pure, and the backend computes the same numbers off-chain. docs/MATH.md
///         states each rule, with worked examples.
/// @dev Units:
///      - prices: `int64` at the market's price exponent (BTC: -8, so $83,884 is 8_388_400_000_000);
///      - amounts: `uint64` base units of the token (USDG has 6 decimals, so $10 is 10_000_000);
///      - the leverage L: a whole number from 1 to 10,000 (1000 is 1000x);
///      - payout multiples (g, floor, cap) and fee rates: basis points, where 10_000 is 1x or 100%;
///      - the liquidation distance θ: `thetaE7 = θ × 1e7`, so 2.627 bp is 2_627.
///      The maths runs in 256-bit integers, where none of these values can overflow, and each result is narrowed
///      once at the end with a range check that reverts `MathOverflow`. Every division rounds down (toward minus
///      infinity in `gBps`, whose dividend is negative on a losing move), which is always in the pool's favour.
///      The functions come in this order: `floorDiv`; the leverage checks (`leverageAllowed`, `thetaWithinLimit`,
///      `capReachable`); the lines and the payout (`lines`, `capLine`, `gBps`, `payout`, `maxProfit`, `touched`);
///      the time checks; the open gate; the fees; the settle split; the sale; the repay split; and the withdrawal
///      check.
/// @custom:security-contact See SECURITY.md
library LeverageMath {
    /// @notice The smallest allowed leverage L (1x). A leverage is a whole number: at L, every 1 bp the price moves
    ///         changes the payout by L/100 % of the stake (10% at 1000x, 5% at 500x, 1% at 100x).
    uint16 internal constant MIN_LEVERAGE = 1;

    /// @notice The largest allowed leverage L (10,000x).
    uint16 internal constant MAX_LEVERAGE = 10_000;

    /// @notice Basis points in 1x (or in 100%).
    uint256 internal constant BPS = 10_000;

    /// @notice The scale of θ: `thetaE7 = θ × 1e7`. A line θ away from entry is `entry × thetaE7 / 1e7` away.
    uint256 internal constant E7 = 10_000_000;

    /// @notice The highest payout cap a position may have, in bps of its stake (40_000 = 4x).
    uint16 internal constant MAX_LEVERAGE_CAP_BPS = 40_000;

    /// @notice The winner fee: 2% of the profit actually paid out (at settle, on a profitable sale, on each repayment).
    uint16 internal constant WINNER_FEE_BPS = 200;

    /// @notice The loser fee: 3% of a loss, taken while the pool's free money is at or above its floor.
    uint16 internal constant LOSER_FEE_BPS = 300;

    /// @notice The most seed recovery can ever take out of the pool, in whole tokens (× 10^decimals).
    uint64 internal constant SEED_RECOVERY_CAP_TOKENS = 500;

    /// @dev Signed copies for the signed maths in `lines` and `gBps`.
    // casting to int256 is safe because BPS (10_000) is far below type(int256).max
    // forge-lint: disable-next-line(unsafe-typecast)
    int256 private constant BPS_SIGNED = int256(BPS);
    // casting to int256 is safe because E7 (10_000_000) is far below type(int256).max
    // forge-lint: disable-next-line(unsafe-typecast)
    int256 private constant E7_SIGNED = int256(E7);

    /// @notice Divides `a` by `b`, rounding toward minus infinity.
    /// @dev Solidity's signed `/` rounds toward zero: `-7 / 2 == -3`, where the floor is -4. For a losing price move
    ///      that difference is money: rounding toward zero would round the loss in the user's favour. The callers
    ///      always divide by a positive price, so `type(int256).min / -1` (which reverts) can't occur.
    /// @param a The dividend.
    /// @param b The divisor; must not be 0 (division by zero panics).
    /// @return q The largest integer `q` with `q × b <= a` when `b > 0`.
    function floorDiv(int256 a, int256 b) internal pure returns (int256 q) {
        q = a / b;
        // A non-zero remainder with operands of opposite signs means `/` rounded up toward zero: step down by one.
        if (a % b != 0 && ((a < 0) != (b < 0))) q -= 1;
    }

    /// @notice Whether `leverage` is in the allowed range, `MIN_LEVERAGE` to `MAX_LEVERAGE` (1x to 10,000x).
    /// @param leverage The leverage L, a whole number (1000 is 1000x).
    /// @return True if the maths accepts it.
    function leverageAllowed(uint16 leverage) internal pure returns (bool) {
        return leverage >= MIN_LEVERAGE && leverage <= MAX_LEVERAGE;
    }

    /// @notice Whether a liquidation distance θ stays below 1/leverage, so the move to a position's line costs less
    ///         than its whole stake: `thetaE7 × leverage < 1e7`. That is under 10 bp at 1000x, 20 bp at 500x and
    ///         100 bp at 100x.
    /// @dev At the line the price has moved θ against the user, so the payout multiple is 1 − L × θ, which stays
    ///      above 0 only while L × θ < 1. The product is taken in 256 bits, where no `uint32` θ times a `uint16`
    ///      leverage can overflow.
    /// @param thetaE7 The liquidation distance θ × 1e7.
    /// @param leverage The leverage L.
    /// @return True if the line comes before a move that would take the whole stake.
    function thetaWithinLimit(uint32 thetaE7, uint16 leverage) internal pure returns (bool) {
        return uint256(thetaE7) * leverage < E7;
    }

    /// @notice Whether a short can reach the cap: `capBps − 10_000 < leverage × 10_000`, that is cap − 1x < L.
    /// @dev A short's payout grows by L × the fall in price, and a price can't fall below 0, so a short gains at most
    ///      L × its stake: a higher cap would put its cap line at or below 0. From 4x leverage up every cap up to the
    ///      4x ceiling passes, so the rule only binds at 1x, 2x and 3x. A cap below 1x counts as 1x (a gain of 0);
    ///      `lines` and the config check reject such a cap anyway.
    /// @param capBps The payout cap, in bps of the stake.
    /// @param leverage The leverage L.
    /// @return True if a short's cap line sits above 0.
    function capReachable(uint16 capBps, uint16 leverage) internal pure returns (bool) {
        uint256 capGainBps = capBps > BPS ? capBps - BPS : 0;
        return capGainBps < uint256(leverage) * BPS;
    }

    /// @notice The liquidation and cap prices of a position opened at `entry` with `leverage`.
    /// @dev The checks run in this order: the price, then the parameters.
    ///      - The liquidation line sits θ away from entry, whatever the leverage: `entry × thetaE7 / 1e7`. At
    ///        $83,884.00, θ = 2.627 bp puts it $22.04 away.
    ///      - The cap line is where the payout multiple reaches the cap: 1 + L × move = cap, so the move is
    ///        (cap − 1x) / L, which is `entry × (capBps − 10_000) / (L × 10_000)`. At 1000x a 4x cap is a
    ///        0.3% move ($251.65 from the same entry), at 500x a 2.5x cap is the same 0.3%, and at 100x a 2x cap is
    ///        1%.
    ///      Both offsets have positive operands, so truncating is flooring: each line sits at most one price unit
    ///      closer to entry. A long loses when the price falls, so its line is below entry and its cap above; a short
    ///      mirrors it.
    /// @param entry The entry price; must be positive (`InvalidPrice`).
    /// @param side `Call` (long) or `Put` (short).
    /// @param leverage The leverage L: `leverageAllowed` (`InvalidLeverageParams`).
    /// @param thetaE7 The liquidation distance θ × 1e7: positive, and `thetaWithinLimit` at L
    ///        (`InvalidLeverageParams`).
    /// @param capBps The payout cap: `10_000 < capBps <= MAX_LEVERAGE_CAP_BPS`, and `capReachable` at L
    ///        (`InvalidLeverageParams`).
    /// @return liqPrice Touching this price (equality counts) liquidates the position.
    /// @return capPrice The cap line, rounded toward the entry: the payout stops growing at this price, or one price
    ///         unit beyond it when the division isn't exact. `MathOverflow` if it doesn't fit `int64`.
    function lines(
        int64 entry,
        Side side,
        uint16 leverage,
        uint32 thetaE7,
        uint16 capBps
    )
        internal
        pure
        returns (int64 liqPrice, int64 capPrice)
    {
        if (entry <= 0) revert IManicFlashOptionErrors.InvalidPrice();
        if (
            !leverageAllowed(leverage) || thetaE7 == 0 || !thetaWithinLimit(thetaE7, leverage) || capBps <= BPS
                || capBps > MAX_LEVERAGE_CAP_BPS || !capReachable(capBps, leverage)
        ) revert IManicFlashOptionErrors.InvalidLeverageParams();
        int256 e = entry;
        int256 liqOffset = (e * int256(uint256(thetaE7))) / E7_SIGNED; // rounds down: the line moves toward entry
        // Rounds down too. L ≥ 1 here (checked above), so the divisor is at least 10_000.
        int256 capOffset = (e * (int256(uint256(capBps)) - BPS_SIGNED)) / (int256(uint256(leverage)) * BPS_SIGNED);
        if (side == Side.Call) {
            return (toInt64(e - liqOffset), toInt64(e + capOffset));
        }
        return (toInt64(e + liqOffset), toInt64(e - capOffset));
    }

    /// @notice The cap line of a position opened at `entry` with `leverage`: the price, rounded toward the entry,
    ///         where its payout stops growing (one price unit beyond it when the division isn't exact). The second line
    /// of `lines` on its own, for a position whose θ isn't stored (`getPosition`).
    /// @dev The same checks and the same arithmetic as `lines`' cap line, which doesn't use θ: the price, then the
    ///      leverage and the cap, then `entry ± entry × (capBps − 10_000) / (L × 10_000)`, rounded toward entry.
    ///      A fuzz test proves it equals `lines`' cap price for every entry, side, leverage and cap. Named for the
    ///      line, since `capPrice` is `lines`' return.
    /// @param entry The entry price; must be positive (`InvalidPrice`).
    /// @param side `Call` (the cap price is above entry) or `Put` (below).
    /// @param leverage The leverage L: `leverageAllowed` (`InvalidLeverageParams`).
    /// @param capBps The payout cap: `10_000 < capBps <= MAX_LEVERAGE_CAP_BPS`, and `capReachable` at L
    ///        (`InvalidLeverageParams`).
    /// @return The cap price. `MathOverflow` if it doesn't fit `int64`.
    function capLine(int64 entry, Side side, uint16 leverage, uint16 capBps) internal pure returns (int64) {
        if (entry <= 0) revert IManicFlashOptionErrors.InvalidPrice();
        if (
            !leverageAllowed(leverage) || capBps <= BPS || capBps > MAX_LEVERAGE_CAP_BPS
                || !capReachable(capBps, leverage)
        ) revert IManicFlashOptionErrors.InvalidLeverageParams();
        int256 e = entry;
        // Rounds down: toward entry. L ≥ 1 here (checked above), so the divisor is at least 10_000.
        int256 capOffset = (e * (int256(uint256(capBps)) - BPS_SIGNED)) / (int256(uint256(leverage)) * BPS_SIGNED);
        return toInt64(side == Side.Call ? e + capOffset : e - capOffset);
    }

    /// @dev `tokens` whole tokens in base units (`tokens × 10^decimals`), reverting `MathOverflow` when `10^decimals`
    ///      or the product doesn't fit `uint64`. `10^20` already exceeds `uint64`, so larger decimals stop early,
    ///      before `10**decimals` could overflow even 256 bits.
    function wholeTokens(uint64 tokens, uint8 decimals) private pure returns (uint64) {
        if (decimals > 19) revert IManicFlashOptionErrors.MathOverflow();
        return toUint64(uint256(tokens) * 10 ** uint256(decimals));
    }

    /// @dev True if `publishTime` is ahead of `currentTime` by more than `clockSkewSecs`, written without adding so
    ///      it can't overflow.
    function isFromTheFuture(uint256 publishTime, uint256 currentTime, uint8 clockSkewSecs)
        private
        pure
        returns (bool)
    {
        return publishTime > currentTime && publishTime - currentTime > clockSkewSecs;
    }

    /// @dev Narrows to `int64`, reverting `MathOverflow` instead of truncating.
    function toInt64(int256 value) private pure returns (int64) {
        if (value < type(int64).min || value > type(int64).max) revert IManicFlashOptionErrors.MathOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        return int64(value); // in range: checked on the line above
    }

    /// @dev Narrows to `uint64`, reverting `MathOverflow` instead of truncating.
    function toUint64(uint256 value) private pure returns (uint64) {
        if (value > type(uint64).max) revert IManicFlashOptionErrors.MathOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(value); // in range: checked on the line above
    }

    /// @dev Narrows a clamped multiple to `uint16`, reverting `MathOverflow` instead of truncating. After `gBps`
    ///      clamps g to `[0, capBps]` this can't fail; the check keeps the cast honest.
    function toUint16(int256 value) private pure returns (uint16) {
        if (value < 0 || value > int256(uint256(type(uint16).max))) revert IManicFlashOptionErrors.MathOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(uint256(value)); // in range: checked on the line above
    }
}
