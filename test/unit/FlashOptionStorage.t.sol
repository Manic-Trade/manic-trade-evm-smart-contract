// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {FlashOptionStorage} from "../../src/base/FlashOptionStorage.sol";
import {Market, Position, Side, Status, WithdrawPurpose} from "../../src/types/StorageTypes.sol";

/// @title FlashOptionStorage_Unit_Test
/// @notice Proves the storage layout the compiler produces is exactly the one designed in docs/ARCHITECTURE.md §6:
///         the ERC-7201 namespace slot, every field's slot and byte offset in `Layout`, `PoolState`, `Breaker`,
///         `Market`, `DurationRule` and `Position`, the five mapping roots, and the values the enums are stored as.
/// @dev How it works: this test contract inherits `FlashOptionStorage`, writes fields through the same
///      `_getFlashOptionStorage()` pointer the contract will use, then reads the raw 32-byte words back with `vm.load`.
///      Each field gets a distinct byte pattern, so each expected word reads like the slot map: Solidity packs a
///      slot from its lowest-order bytes up, so the first field declared is at the right-hand end of the word. A
///      field that is reordered, resized or inserted moves bytes and fails a test here. The slot maps are also
///      written out in docs/storage-layout.md.
contract FlashOptionStorage_Unit_Test is Test, FlashOptionStorage {
    /// @dev `cast index-erc7201 manic.storage.FlashOption`.
    bytes32 internal constant NAMESPACE_SLOT = 0xf273be9a24eeab036a40c6c3509d6aa7cccb8da2ecbd9965c4f2a996a54c2200;

    /// @dev Where each mapping's root sits in `Layout`. An entry lives at keccak256(abi.encode(key, root slot)).
    uint256 internal constant MARKETS_ROOT = 9;
    uint256 internal constant MARKET_INDEX_ROOT = 10;
    uint256 internal constant POSITIONS_ROOT = 11;
    uint256 internal constant IOU_QUEUE_ROOT = 12;
    uint256 internal constant CLAIMABLE_ROOT = 13;

    /// @dev Distinct byte patterns, so every field is visible in the raw word.
    uint64 internal constant P1 = 0x3132333435363738;
    uint64 internal constant P2 = 0x2122232425262728;
    uint64 internal constant P3 = 0x1112131415161718;
    uint64 internal constant P4 = 0x0102030405060708;
    address internal constant ADDR_A = 0x0102030405060708090a0B0c0d0e0f1011121314;
    address internal constant ADDR_B = 0x2122232425262728292A2b2C2D2e2f3031323334;
    address internal constant ADDR_C = 0x4142434445464748494a4b4c4D4E4F5051525354;

    // ---------------------------------------------------------------------------------------------------------------
    // The namespace
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The slot is the ERC-7201 formula of "manic.storage.FlashOption", and the accessor points at it.
    function test_TheNamespaceSlotFollowsErc7201() public pure {
        bytes32 formula =
            keccak256(abi.encode(uint256(keccak256("manic.storage.FlashOption")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(formula, NAMESPACE_SLOT, "the formula gives the pinned slot");
        assertEq(_root(), NAMESPACE_SLOT, "the accessor points at the namespace");
        assertEq(uint256(NAMESPACE_SLOT) & 0xff, 0, "the namespace starts on a 256-slot boundary");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Layout: slots 0-2
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Slot 0 packs token, tokenDecimals, halted, marketCount and refundDelaySecs into 30 bytes; slots 1 and 2
    ///      hold the two recipients.
    function test_TheLayoutSettingsPackAsDesigned() public {
        Layout storage $ = _getFlashOptionStorage();
        $.token = IERC20(ADDR_A);
        $.tokenDecimals = 0x15;
        $.halted = true;
        $.marketCount = 0x1617;
        $.refundDelaySecs = 0x18191A1B1C1D;
        $.feeRecipient = ADDR_B;
        $.rewardsRecipient = ADDR_C;

        // [2 unused][refundDelaySecs 6][marketCount 2][halted 1][tokenDecimals 1][token 20]
        assertEq(_word(0), 0x000018191a1b1c1d161701150102030405060708090a0b0c0d0e0f1011121314, "slot 0");
        assertEq(_word(1), uint256(uint160(ADDR_B)), "slot 1: feeRecipient");
        assertEq(_word(2), uint256(uint160(ADDR_C)), "slot 2: rewardsRecipient");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Layout: PoolState (slots 3-6) and Breaker (slots 7-8)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The pool's books take slots 3 to 6, with free bytes only at the end of slot 6.
    function test_ThePoolBooksPackIntoSlotsThreeToSix() public {
        Layout storage $ = _getFlashOptionStorage();
        $.pool.total = P1;
        $.pool.lockedMargin = P2;
        $.pool.openMaxProfit = P3;
        $.pool.totalOwed = P4;
        $.pool.poolFloor = P1;
        $.pool.nextQueueSeq = P2;
        $.pool.nextRepaySeq = P3;
        $.pool.openPositions = 0x05060708;
        $.pool.owedPositions = 0x01020304;
        $.pool.feesPending = P1;
        $.pool.totalClaimable = P2;
        $.pool.transferred = P3;
        $.pool.feesPaid = P4;
        $.pool.seedRecovered = P1;
        $.pool.rewardsWithdrawn = P2;

        // [totalOwed][openMaxProfit][lockedMargin][total]
        assertEq(_word(3), 0x0102030405060708111213141516171821222324252627283132333435363738, "slot 3");
        // [owedPositions 4][openPositions 4][nextRepaySeq 8][nextQueueSeq 8][poolFloor 8]
        assertEq(_word(4), 0x0102030405060708111213141516171821222324252627283132333435363738, "slot 4");
        // [feesPaid][transferred][totalClaimable][feesPending]
        assertEq(_word(5), 0x0102030405060708111213141516171821222324252627283132333435363738, "slot 5");
        // [16 unused][rewardsWithdrawn][seedRecovered]
        assertEq(_word(6), 0x0000000000000000000000000000000021222324252627283132333435363738, "slot 6");
    }

    /// @dev The circuit breaker takes slots 7 and 8: the current window in slot 7 (the only slot a counted batch
    ///      writes), the limit alone in slot 8.
    function test_TheBreakerPacksIntoSlotsSevenAndEight() public {
        Layout storage $ = _getFlashOptionStorage();
        $.breaker.profitOut = P1;
        $.breaker.lossIn = P2;
        $.breaker.windowStart = 0x111213141516;
        $.breaker.tripped = true;
        $.breaker.windowSecs = 0x0A0B0C0D;
        $.breaker.maxNetProfit = P1;

        // [5 unused][windowSecs 4][tripped 1][windowStart 6][lossIn 8][profitOut 8]
        assertEq(_word(7), 0x00000000000a0b0c0d0111121314151621222324252627283132333435363738, "slot 7");
        // [24 unused][maxNetProfit 8]
        assertEq(_word(8), P1, "slot 8: maxNetProfit");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Layout: the mapping roots (slots 9-13)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Each mapping's entries hash from its own root slot, 9 to 13, and the root slots themselves stay empty.
    function test_TheMappingsHashFromSlotsNineToThirteen() public {
        Layout storage $ = _getFlashOptionStorage();
        bytes32 marketId = keccak256("BTC/USD");
        bytes32 marketKey = keccak256(abi.encode(marketId, uint16(1000))); // a market's key: its feed and leverage
        bytes32 positionId = keccak256("position");
        $.markets[7].marketId = marketId;
        $.marketIndexPlusOne[marketKey] = 8;
        $.positions[positionId].user = ADDR_A;
        $.iouQueue[5] = positionId;
        $.claimable[ADDR_B] = P1;

        assertEq(_entry(bytes32(uint256(7)), MARKETS_ROOT, 0), uint256(marketId), "markets[7].marketId");
        assertEq(_entry(marketKey, MARKET_INDEX_ROOT, 0), 8, "marketIndexPlusOne[keccak256(marketId, leverage)]");
        assertEq(_entry(positionId, POSITIONS_ROOT, 0), uint256(uint160(ADDR_A)), "positions[id].user");
        assertEq(_entry(bytes32(uint256(5)), IOU_QUEUE_ROOT, 0), uint256(positionId), "iouQueue[5]");
        assertEq(_entry(bytes32(uint256(uint160(ADDR_B))), CLAIMABLE_ROOT, 0), P1, "claimable[account]");
        for (uint256 slot = MARKETS_ROOT; slot <= CLAIMABLE_ROOT; ++slot) {
            assertEq(_word(slot), 0, "a mapping's root slot holds nothing");
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Market (8 slots) and DurationRule (1 slot)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A market takes 8 slots: the id, every setting read on open and sale in one slot, the stake and owed
    ///      limits with the leverage, then one slot per duration rule.
    function test_AMarketPacksIntoEightSlots() public {
        Market storage m = _getFlashOptionStorage().markets[3];
        m.marketId = keccak256("BTC/USD");
        m.enabled = true;
        m.paused = false;
        m.priceExponent = -8;
        m.entryMaxAgeSecs = 0x0A;
        m.clockSkewSecs = 0x0B;
        m.floorMinBps = 0x1112;
        m.floorMaxBps = 0x1314;
        m.capMinBps = 0x1516;
        m.capMaxBps = 0x1718;
        m.maxSellFeeBps = 0x191A;
        m.sellMinDelaySecs = 0x1B1C;
        m.sellCutoffSecs = 0x1D1E;
        m.maxExposureBps = 0x21222324;
        m.minStake = P1;
        m.maxStake = P1;
        m.maxTotalOwed = P2;
        m.leverage = 0x4142;
        for (uint256 i; i < 5; ++i) {
            m.durations[i].durationSecs = uint16(60 * (i + 1));
            m.durations[i].thetaMinE7 = uint32(2000 + i);
            m.durations[i].thetaMaxE7 = uint32(9000 + i);
            m.durations[i].enabled = i % 2 == 0;
        }

        bytes32 key = bytes32(uint256(3));
        assertEq(_entry(key, MARKETS_ROOT, 0), uint256(keccak256("BTC/USD")), "slot 0: marketId");
        // [1 unused][minStake 8][maxExposureBps 4][sellCutoffSecs][sellMinDelaySecs][maxSellFeeBps][capMaxBps]
        // [capMinBps][floorMaxBps][floorMinBps][clockSkewSecs 1][entryMaxAgeSecs 1][priceExponent 1 (-8 = f8)]
        // [paused 1][enabled 1]
        assertEq(
            _entry(key, MARKETS_ROOT, 1),
            0x003132333435363738212223241d1e1b1c191a17181516131411120b0af80001,
            "slot 1: the settings read on every open and sale"
        );
        // [14 unused][leverage 2][maxTotalOwed][maxStake]: the leverage (ADR 0008) fills unused bytes, so nothing moves
        assertEq(
            _entry(key, MARKETS_ROOT, 2),
            0x0000000000000000000000000000414221222324252627283132333435363738,
            "slot 2: maxStake, maxTotalOwed, leverage"
        );
        for (uint256 i; i < 5; ++i) {
            // [21 unused][enabled 1][thetaMaxE7 4][thetaMinE7 4][durationSecs 2]
            uint256 rule = 60 * (i + 1) | (2000 + i) << 16 | (9000 + i) << 48 | uint256(i % 2 == 0 ? 1 : 0) << 80;
            assertEq(_entry(key, MARKETS_ROOT, 3 + i), rule, "slots 3-7: one duration rule per slot");
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Position (3 slots)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Slot 0 is exactly full (the tombstone), slot 1 holds what a closed position no longer needs, and slot 2
    ///      is the IOU.
    function test_APositionPacksIntoThreeSlots() public {
        bytes32 positionId = keccak256("position");
        Position storage p = _getFlashOptionStorage().positions[positionId];
        p.user = ADDR_A;
        p.marketIdx = 0x1516;
        p.side = Side.Put;
        p.status = Status.Owed;
        p.startTime = 0x18191A1B1C1D;
        p.durationSecs = 0x1E1F;
        p.stake = P1;
        p.entryPrice = int64(P2);
        p.liqPrice = int64(P3);
        p.floorBps = 0x0506;
        p.capBps = 0x0304;
        p.leverage = 0x4142;
        p.owed = P1;
        p.queueSeq = P2;

        // [durationSecs 2][startTime 6][status 1 (Owed = 2)][side 1 (Put = 1)][marketIdx 2][user 20]: all 32 bytes
        assertEq(
            _entry(positionId, POSITIONS_ROOT, 0),
            0x1e1f18191a1b1c1d020115160102030405060708090a0b0c0d0e0f1011121314,
            "slot 0: the tombstone"
        );
        // [2 unused][leverage 2][capBps 2][floorBps 2][liqPrice 8][entryPrice 8][stake 8]: the leverage (ADR 0008)
        // fills unused bytes, so nothing moves
        assertEq(
            _entry(positionId, POSITIONS_ROOT, 1),
            0x0000414203040506111213141516171821222324252627283132333435363738,
            "slot 1: stake, prices, floor, cap and leverage"
        );
        // [16 unused][queueSeq][owed]
        assertEq(
            _entry(positionId, POSITIONS_ROOT, 2),
            0x0000000000000000000000000000000021222324252627283132333435363738,
            "slot 2: the IOU"
        );
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Enums
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Enums are stored as uint8, so their values can never change; a new member goes at the end, and this test
    ///      is updated with it.
    function test_EnumsKeepTheirStoredValues() public pure {
        assertEq(uint8(Side.Call), 0);
        assertEq(uint8(Side.Put), 1);
        assertEq(uint8(type(Side).max), 1, "Side has 2 members");
        assertEq(uint8(WithdrawPurpose.SeedRecovery), 0);
        assertEq(uint8(WithdrawPurpose.Rewards), 1);
        assertEq(uint8(type(WithdrawPurpose).max), 1, "WithdrawPurpose has 2 members");
        assertEq(uint8(Status.None), 0);
        assertEq(uint8(Status.Open), 1);
        assertEq(uint8(Status.Owed), 2);
        assertEq(uint8(Status.Closed), 3);
        assertEq(uint8(type(Status).max), 3, "Status has 4 members");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The slot `_getFlashOptionStorage()` points at.
    function _root() internal pure returns (bytes32 slot) {
        Layout storage $ = _getFlashOptionStorage();
        assembly ("memory-safe") {
            slot := $.slot
        }
    }

    /// @dev The raw word in `Layout` slot `offset`.
    function _word(uint256 offset) internal view returns (uint256) {
        return uint256(vm.load(address(this), bytes32(uint256(_root()) + offset)));
    }

    /// @dev The raw word `offset` slots into the mapping entry `key` of the mapping whose root is `Layout` slot
    ///      `rootOffset`.
    function _entry(bytes32 key, uint256 rootOffset, uint256 offset) internal view returns (uint256) {
        bytes32 base = keccak256(abi.encode(key, uint256(_root()) + rootOffset));
        return uint256(vm.load(address(this), bytes32(uint256(base) + offset)));
    }
}
