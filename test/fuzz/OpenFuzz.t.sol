// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, OpenTerms, StakeAuth} from "../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {DurationRule, PoolState, Position, Side, Status} from "../../src/types/StorageTypes.sol";
import {Base_Test} from "../Base.t.sol";
import {Defaults} from "../utils/Defaults.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";
import {LeverageConfigs} from "../utils/LeverageConfigs.sol";

/// @title Open_Fuzz_Test
/// @notice `open`, for random orders and terms (docs/ARCHITECTURE.md §8.2):
///         - a relayer that changes any one signed field of alice's order is refused (`InvalidSignature`), so it can
///           never open a bet she didn't sign: not on another market, and not at another leverage;
///         - any open inside the bounds of a market at any leverage takes exactly the stake, records exactly the terms
///           and the market's leverage, puts the line where its formula says, and holds exactly the stake and its max
///           profit in the books, which stay balanced.
/// @dev ETH at 1000x and BTC at 500x are created and switched on too, so a changed market id or leverage still names
///      a market and reaches the signature check. The in-bounds property runs on BTC at the case's leverage
///      (`_leverageFor`), with the launch config fitted to it (`LeverageConfigs.launchAt`). Max profit and the line
///      are computed here independently: stake × (cap − 1) rounded down, and θ × the entry / 1e7 rounded
///      down, away from the entry on the losing side, whatever the leverage. Inputs are bounded with `bound`, never
///      `vm.assume`. CI runs 10,000 cases per property.
contract Open_Fuzz_Test is Base_Test {
    /// @dev The random terms of a bet, and the seed of its market's leverage.
    struct Terms {
        uint64 stake;
        uint8 ruleIndex;
        uint32 thetaE7;
        uint16 floorBps;
        uint16 capBps;
        bool isPut;
        int64 entryPrice;
        uint16 leverageSeed;
    }

    uint64 internal constant FREE = 1500e6;

    /// @dev BTC's second market, which a changed leverage names.
    uint16 internal constant OTHER_LEVERAGE = 500;

    uint256 internal aliceKey;

    function setUp() public override {
        super.setUp();
        aliceKey = _keyOf("alice");
        _fund(users.bob, FREE);
        vm.prank(users.admin);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, Defaults.marketConfig());
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.ETH, Defaults.LEVERAGE, _enabledConfig());
        _useBtcAt(OTHER_LEVERAGE, _enabledConfig());
    }

    function testFuzz_ARelayerThatChangesAnySignedFieldIsRefused(uint8 field, uint256 noise) external {
        OpenOrder memory o = _order(users.alice, keccak256("alice's bet"));
        _mintUsdg(users.alice, o.stake);
        bytes memory signature = _signOrder(flashOption, aliceKey, o);
        StakeAuth memory a = _stakeAuth(flashOption, aliceKey, o);

        // One field changed, to a value every check before the signature still accepts.
        uint256 flip = noise | 1; // odd, so XOR-ing any of its low bits into a field changes it
        field %= 9;
        if (field == 0) {
            // Never zero: a zero id is refused one check earlier (`PositionIdUsed`). The fuzzer does try the id itself
            // as `noise`, which XORs it to zero.
            o.positionId = bytes32(uint256(o.positionId) ^ flip);
            if (o.positionId == bytes32(0)) o.positionId = bytes32(uint256(1));
        } else if (field == 1) {
            o.user = users.bob;
        } else if (field == 2) {
            o.marketId = Defaults.ETH;
        } else if (field == 3) {
            o.leverage = OTHER_LEVERAGE;
        } else if (field == 4) {
            o.side = Side.Put;
        } else if (field == 5) {
            o.stake ^= uint64(flip);
        } else if (field == 6) {
            o.durationSecs ^= uint16(flip);
        } else if (field == 7) {
            o.notBefore ^= uint48(flip);
        } else {
            o.deadline = uint48(bound(noise, o.deadline + 1, type(uint48).max));
        }

        vm.expectRevert(Errors.InvalidSignature.selector);
        vm.prank(users.opener);
        flashOption.open(o, signature, _terms(), a);
    }

    function testFuzz_AnOpenInsideTheBoundsMovesExactlyTheStake(Terms memory r) external {
        uint16 marketLeverage = _leverageFor(r.leverageSeed);
        ConfigParams memory c = LeverageConfigs.launchAt(marketLeverage);
        c.maxExposureBps = 10_000;
        _useBtcAt(marketLeverage, c);
        DurationRule memory rule = c.durations[r.ruleIndex % 5];
        OpenOrder memory o = _order(users.alice, keccak256(abi.encode(r)));
        o.leverage = marketLeverage;
        o.stake = uint64(bound(r.stake, c.minStake, c.maxStake));
        o.durationSecs = rule.durationSecs;
        o.side = r.isPut ? Side.Put : Side.Call;
        OpenTerms memory t = _terms();
        t.thetaE7 = uint32(bound(r.thetaE7, rule.thetaMinE7, rule.thetaMaxE7));
        t.floorBps = uint16(bound(r.floorBps, c.floorMinBps, c.floorMaxBps));
        t.capBps = uint16(bound(r.capBps, t.floorBps > c.capMinBps ? t.floorBps : c.capMinBps, c.capMaxBps));
        t.entryPrice = int64(bound(r.entryPrice, 1, type(int64).max / 2));
        PoolState memory before = LayoutReader.pool(address(flashOption));

        _open(aliceKey, o, t);

        uint64 maxProfit = uint64(uint256(o.stake) * (t.capBps - 10_000) / 10_000);
        PoolState memory afterwards = LayoutReader.pool(address(flashOption));
        assertEq(afterwards.total, before.total + o.stake, "total");
        assertEq(afterwards.lockedMargin, before.lockedMargin + o.stake, "held margin");
        assertEq(afterwards.openMaxProfit, before.openMaxProfit + maxProfit, "open max profit");
        assertEq(afterwards.openPositions, before.openPositions + 1, "open positions");
        assertEq(usdg.balanceOf(users.alice), 0, "alice paid exactly her stake");
        assertEq(usdg.balanceOf(address(flashOption)), uint256(FREE) + o.stake, "the pool holds exactly it");
        _assertBooksBalanced(address(flashOption));

        Position memory p = LayoutReader.position(address(flashOption), o.positionId);
        assertEq(uint8(p.status), uint8(Status.Open), "open");
        assertEq(p.stake, o.stake, "stake");
        assertEq(uint8(p.side), uint8(o.side), "side");
        assertEq(p.durationSecs, o.durationSecs, "duration");
        assertEq(p.entryPrice, t.entryPrice, "entry price");
        assertEq(p.floorBps, t.floorBps, "floor");
        assertEq(p.capBps, t.capBps, "cap");
        assertEq(p.startTime, t.entryPublishTime, "start");
        assertEq(p.leverage, marketLeverage, "the market's leverage");
        // The line sits θ × the entry / 1e7 from it, rounded down, whatever the leverage (which only limits θ):
        // below
        // the entry for a call, above it for a put.
        // casting to int64 is safe: the distance is less than the entry
        int64 distance = int64((int256(t.entryPrice) * int256(uint256(t.thetaE7))) / 1e7);
        assertEq(p.liqPrice, o.side == Side.Call ? t.entryPrice - distance : t.entryPrice + distance, "the line");
    }
}
