// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {OpenOrder, OpenTerms, SellOrder} from "../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {DurationRule, PoolState, Position, Side} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {Settlement} from "../utils/Calculations.sol";
import {Defaults} from "../utils/Defaults.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";

/// @title Rounding_Fuzz_Test
/// @notice Rounding at the smallest stakes, 1 to 100 base units ($0.000001 to $0.0001), where one unit of rounding is
///         a large share of the bet (docs/ARCHITECTURE.md §10, security checklist MATH-3):
///         - a tiny bet, on either side, at any price that doesn't touch its line, settles exactly as the checkers'
///           model says, and the pool never pays out more than the exact, unrounded payout and loser fee: each
///           division rounds for the pool;
///         - opening and then selling at the same price, round after round, never leaves the user richer or the
///           pool poorer, whatever valuation and fee the relayer quotes.
/// @dev The market here accepts stakes from 1 base unit; every other setting is the launch config. The checkers
///      (`_expectSettled`, `_expectSold`) compare every field, balance, log and slot with a model built from
///      `Calculations`, which never calls `LeverageMath`, so these also show tiny amounts move as tokens correctly:
/// fees that round to nothing, payouts of a few units. Inputs are bounded with `bound`, never `vm.assume`. CI runs
///      10,000 cases per property.
contract Rounding_Fuzz_Test is Settlement_Base_Test {
    /// @notice The smallest and largest tiny stake, in base units.
    uint64 internal constant TINY_MIN = 1;
    uint64 internal constant TINY_MAX = 100;

    function setUp() public override {
        super.setUp();
        ConfigParams memory c = _enabledConfig();
        c.minStake = TINY_MIN;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
    }

    /// @dev A tiny bet settles exactly as the model says, and the pool pays out no more than the exact amounts: the
    ///      payout is at most stake × g / 10_000, and the loser fee at most 3% of the loss, as real numbers.
    function testFuzz_ATinyBetSettlesForThePool(
        uint64 stake,
        bool isPut,
        uint32 thetaE7,
        uint16 floorBps,
        uint16 capBps,
        int256 price
    )
        external
    {
        OpenOrder memory o = _order(users.alice, "the bet");
        o.stake = uint64(bound(stake, TINY_MIN, TINY_MAX));
        o.side = isPut ? Side.Put : Side.Call;
        Position memory p = _betWith(o, _tinyTerms(thetaE7, floorBps, capBps));

        // Any price short of the line, out to 0.5% the other way: a loss, a win at the floor, or a capped win.
        int64 entry = p.entryPrice;
        int64 settlePrice = isPut
            ? int64(bound(price, int256(entry - entry / 200), int256(p.liqPrice - 1)))
            : int64(bound(price, int256(p.liqPrice + 1), int256(entry + entry / 200)));
        vm.warp(_end(p));
        Settlement memory s = _expectSettled(settlePrice, _end(p), _ids("the bet"))[0].s;

        assertLe(uint256(s.payout) * 10_000, uint256(p.stake) * s.g, "the payout rounds down");
        uint64 own = s.payout < p.stake ? s.payout : p.stake;
        assertLe(uint256(s.loserFee) * 10_000, uint256(p.stake - own) * 300, "the loser fee rounds down");
        if (s.g <= 10_000) assertLe(s.toUser, p.stake, "no win pays back more than the stake");
    }

    /// @dev Open then sell at the same price, one to five rounds of tiny stakes, with any valuation up to what the
    ///      position pays (its stake, at 1x) and any fee up to the cap: after every round the user has lost or broken
    ///      even, and the pool's free money has grown or held.
    function testFuzz_OpenThenSellAtTheSamePriceNeverPaysTheUser(uint256 rounds, uint256 seed) external {
        rounds = bound(rounds, 1, 5);
        for (uint256 i; i < rounds; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bytes32 id = keccak256(abi.encode("round", i));
            OpenOrder memory o = _order(users.alice, id);
            o.stake = uint64(bound(r, TINY_MIN, TINY_MAX));
            o.side = (r >> 64) % 2 == 0 ? Side.Call : Side.Put;
            PoolState memory before = LayoutReader.pool(address(flashOption));
            Position memory p = _betWith(o, _terms());

            uint64 valuation = uint64(bound(r >> 72, 0, p.stake)); // at 1x the position pays its stake
            uint64 sellAmount = valuation - uint64(bound(r >> 136, 0, uint256(valuation) * 600 / 10_000));
            SellOrder memory s = _sellOrder(id, uint64(bound(r >> 200, 0, sellAmount)));
            bytes memory signature = _signSell(aliceKey, s); // before the prank in the checker: signing calls the
            // contract
            uint64 toUser = _expectSold(s, signature, _sellTerms(p.entryPrice, valuation, sellAmount)).sale.toUser;

            assertLe(toUser, p.stake, "the user never ends a round richer");
            PoolState memory afterwards = LayoutReader.pool(address(flashOption));
            assertGe(
                uint256(afterwards.total) - afterwards.lockedMargin,
                uint256(before.total) - before.lockedMargin,
                "the pool's free money never shrinks"
            );
        }
        _assertBooksBalanced(address(flashOption));
    }

    /// @dev The relayer's terms for a 60-second bet at the base price, now, with θ, floor and cap drawn inside the
    ///      market's bounds.
    function _tinyTerms(uint32 thetaE7, uint16 floorBps, uint16 capBps) private view returns (OpenTerms memory t) {
        ConfigParams memory c = _enabledConfig();
        DurationRule memory rule = c.durations[0];
        t = _terms();
        t.thetaE7 = uint32(bound(thetaE7, rule.thetaMinE7, rule.thetaMaxE7));
        t.floorBps = uint16(bound(floorBps, c.floorMinBps, c.floorMaxBps));
        t.capBps = uint16(bound(capBps, t.floorBps > c.capMinBps ? t.floorBps : c.capMinBps, c.capMaxBps));
    }
}
