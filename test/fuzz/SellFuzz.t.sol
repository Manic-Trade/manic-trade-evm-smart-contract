// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, OpenTerms, SellOrder, SellTerms} from "../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {DurationRule, PoolState, Position, Side} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {Calculations} from "../utils/Calculations.sol";
import {Defaults} from "../utils/Defaults.sol";
import {Examples} from "../utils/Examples.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";
import {LeverageConfigs} from "../utils/LeverageConfigs.sol";

/// @title Sell_Fuzz_Test
/// @notice `sell`, for random orders and random quotes (docs/ARCHITECTURE.md §8.3):
///         - a relayer that changes any one signed field of alice's sale order is refused (`InvalidSignature`), so
///           it can never sell her position for less than she signed, or at a tick before she signed;
///         - any sale inside the bounds (any bet, on a market at any leverage, any price that doesn't touch its line,
///           any valuation the position and the pool can pay, any fee up to the cap, any minimum up to the sale
///           amount, on a pool of any size and floor, with alice possibly frozen) matches the checkers' model in every
///           field, and leaves the contract holding exactly its books;
///         - a sale valued one unit above what the bet pays now, at its own leverage, is refused
///           (`ValuationAboveCurrentPayout`), and one valued at exactly that sells.
/// @dev Inputs are bounded with `bound`, never `vm.assume`. The model (`Calculations.sell`, `Calculations.gBps`) never
///      calls `LeverageMath`, so the second property is also a differential test of `checkSell`'s bounds and
///      `sellSplit`. The last two properties' bets are on BTC at the case's leverage (`_leverageFor`), with the launch
///      config fitted to it (`LeverageConfigs.launchAt`), priced within 4 / L of the entry (`_priceNear`). A contract
///      that valued a bet at a lower leverage than its own would refuse fair sales, which the second property catches;
///      at a higher one, it would let a relayer pay a bet more than it is worth, which the third catches. CI runs
///      10,000 cases per property.
contract Sell_Fuzz_Test is Settlement_Base_Test {
    /// @dev The random terms of a bet and of its sale, and the seed of its market's leverage.
    struct Terms {
        uint64 stake;
        uint8 ruleIndex;
        uint32 thetaE7;
        uint16 floorBps;
        uint16 capBps;
        bool isPut;
        int64 price;
        uint64 valuation;
        uint64 fee;
        uint64 minAmount;
        uint16 secondsIn;
        uint16 leverageSeed;
    }

    function testFuzz_ARelayerThatChangesAnySignedFieldIsRefused(uint8 field, uint256 noise) external {
        _bet(users.alice, "alice's bet", Side.Call);
        _bet(users.bob, "bob's bet", Side.Call);
        SellOrder memory s = _sellOrder("alice's bet", 9_000_000);
        bytes memory signature = _signSell(aliceKey, s);
        SellTerms memory t = _sellTerms(Examples.P0, 10_000_000, 10_000_000);

        // One field changed, to a value every check before the signature still accepts.
        uint256 flip = noise | 1; // odd, so XOR-ing any of its low bits into a field changes it
        field %= 4;
        if (field == 0) {
            s.positionId = "bob's bet"; // another open position: a random id would fail one check earlier
        } else if (field == 1) {
            s.minAmount ^= uint64(flip);
        } else if (field == 2) {
            s.notBefore ^= uint48(flip);
        } else {
            s.deadline = uint48(bound(noise, s.deadline + 1, type(uint48).max));
        }

        vm.expectRevert(Errors.InvalidSignature.selector);
        vm.prank(users.opener);
        flashOption.sell(s, signature, t);
    }

    function testFuzz_AnySaleInsideTheBoundsMatchesTheModel(
        Terms memory r,
        uint64 free,
        uint64 poolFloor,
        bool frozen
    )
        external
    {
        // A pool of any size, with the exposure gate off, and any floor.
        _useSmallPool(uint64(bound(free, 1, 3000e6)));
        vm.prank(users.admin);
        flashOption.setPoolFloor(uint64(bound(poolFloor, Defaults.POOL_FLOOR, 5000e6)));

        // Any bet inside the rules of BTC's market at any leverage, its gate off too, sold at any second of its sell
        // window.
        uint16 marketLeverage = _leverageFor(r.leverageSeed);
        ConfigParams memory c = LeverageConfigs.launchAt(marketLeverage);
        _useBtcAt(marketLeverage, c);
        _switchOffOpenGate(address(flashOption), Defaults.BTC, marketLeverage);
        DurationRule memory rule = c.durations[r.ruleIndex % 5];
        Position memory p = _openRandom(c, marketLeverage, rule, r);
        vm.warp(p.startTime + bound(r.secondsIn, 0, rule.durationSecs - c.sellCutoffSecs - 1));

        SellTerms memory t = _randomQuote(p, r, c.maxSellFeeBps);
        SellOrder memory s = _sellOrder("the bet", uint64(bound(r.minAmount, 0, t.sellAmount)));
        bytes memory signature = _signSell(aliceKey, s);
        if (frozen) {
            vm.prank(usdgAdmin);
            usdg.freeze(users.alice);
        }

        _expectSold(s, signature, t);
        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.openPositions, 0, "the bet ended");
        assertEq(
            usdg.balanceOf(address(flashOption)),
            uint256(pool.total) + pool.feesPending + pool.totalClaimable,
            "the contract holds exactly its books"
        );
    }

    function testFuzz_ASaleValuedAboveWhatTheBetPaysIsRefused(Terms memory r) external {
        // Any bet inside the rules of BTC's market at any leverage, its gate at 100%, at any second of its sell window.
        uint16 marketLeverage = _leverageFor(r.leverageSeed);
        ConfigParams memory c = LeverageConfigs.launchAt(marketLeverage);
        _useBtcAt(marketLeverage, c);
        DurationRule memory rule = c.durations[r.ruleIndex % 5];
        Position memory p = _openRandom(c, marketLeverage, rule, r);
        vm.warp(p.startTime + bound(r.secondsIn, 0, rule.durationSecs - c.sellCutoffSecs - 1));

        // What the bet pays now, at its own leverage: the most a sale may value it at.
        int64 price = _untouchedPrice(p, r.price);
        // casting to uint64 is safe: at most the stake × the cap, $200
        uint64 pays = uint64(
            uint256(p.stake) * Calculations.gBps(p.entryPrice, price, p.side, marketLeverage, p.floorBps, p.capBps)
                / 10_000
        );
        SellOrder memory s = _sellOrder("the bet", 0);
        _expectSellReverts(
            s,
            _sellTerms(price, pays + 1, pays + 1),
            abi.encodeWithSelector(Errors.ValuationAboveCurrentPayout.selector)
        );
        _expectSold(s, _signSell(aliceKey, s), _sellTerms(price, pays, pays));
    }

    /// @dev Opens alice's bet on the market at `marketLeverage`, whose settings are `c`, with random terms bounded
    ///      inside them, for `rule`'s duration, at the base price.
    function _openRandom(
        ConfigParams memory c,
        uint16 marketLeverage,
        DurationRule memory rule,
        Terms memory r
    )
        private
        returns (Position memory)
    {
        OpenOrder memory o = _order(users.alice, "the bet");
        o.leverage = marketLeverage;
        o.stake = uint64(bound(r.stake, c.minStake, c.maxStake));
        o.durationSecs = rule.durationSecs;
        o.side = r.isPut ? Side.Put : Side.Call;
        OpenTerms memory t = _terms();
        t.thetaE7 = uint32(bound(r.thetaE7, rule.thetaMinE7, rule.thetaMaxE7));
        t.floorBps = uint16(bound(r.floorBps, c.floorMinBps, c.floorMaxBps));
        t.capBps = uint16(bound(r.capBps, t.floorBps > c.capMinBps ? t.floorBps : c.capMinBps, c.capMaxBps));
        return _betWith(o, t);
    }

    /// @dev A quote inside every bound: a price that doesn't touch the line (`_untouchedPrice`), a valuation up to what
    ///      the position pays and the pool can pay, and a fee up to the cap. Published now.
    function _randomQuote(
        Position memory p,
        Terms memory r,
        uint16 maxSellFeeBps
    )
        private
        view
        returns (SellTerms memory t)
    {
        int64 price = _untouchedPrice(p, r.price);
        uint256 payout = uint256(p.stake)
            * Calculations.gBps(p.entryPrice, price, p.side, p.leverage, p.floorBps, p.capBps) / 10_000;
        PoolState memory pool = LayoutReader.pool(address(flashOption));
        uint256 payable_ = uint256(pool.total) - pool.lockedMargin + p.stake;
        uint64 valuation = uint64(bound(r.valuation, 0, payout < payable_ ? payout : payable_));
        uint64 maxFee = uint64(uint256(valuation) * maxSellFeeBps / 10_000);
        uint64 sellAmount = valuation - uint64(bound(r.fee, 0, maxFee));
        t = _sellTerms(price, valuation, sellAmount);
    }

    /// @dev A price from `raw` within 4 / L of `p`'s entry (`_priceNear`, 0.4% at 1000x), L being its leverage, that
    ///      doesn't touch its line: moved just inside it if it would.
    function _untouchedPrice(Position memory p, int64 raw) private pure returns (int64 price) {
        price = _priceNear(p.entryPrice, p.leverage, raw);
        if (p.side == Side.Call && price <= p.liqPrice) price = p.liqPrice + 1;
        if (p.side == Side.Put && price >= p.liqPrice) price = p.liqPrice - 1;
    }
}
