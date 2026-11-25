// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";

import {Breaker, Market, PoolState, Position, Side, Status} from "../../src/types/StorageTypes.sol";

/// @title LayoutReader
/// @notice Reads the contract's storage straight from its slots, so a test can check every field a function writes,
///         including fields no view function returns.
/// @dev It decodes the slot map that test/unit/FlashOptionStorage.t.sol proves and docs/storage-layout.md lists. `word`
///      returns a whole 32-byte slot, so a test can also check that nothing else in it changed.
library LayoutReader {
    /// @dev Foundry's cheatcode address.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev The namespace's slot: `cast index-erc7201 manic.storage.FlashOption`.
    uint256 internal constant ROOT = 0xf273be9a24eeab036a40c6c3509d6aa7cccb8da2ecbd9965c4f2a996a54c2200;

    /// @notice The raw word in `Layout` slot `offset` of the contract at `target`.
    function word(address target, uint256 offset) internal view returns (uint256) {
        return uint256(VM.load(target, bytes32(ROOT + offset)));
    }

    function token(address target) internal view returns (address) {
        return address(uint160(word(target, 0)));
    }

    function tokenDecimals(address target) internal view returns (uint8) {
        return uint8(word(target, 0) >> 160);
    }

    function halted(address target) internal view returns (bool) {
        return uint8(word(target, 0) >> 168) != 0;
    }

    function marketCount(address target) internal view returns (uint16) {
        return uint16(word(target, 0) >> 176);
    }

    function refundDelaySecs(address target) internal view returns (uint48) {
        return uint48(word(target, 0) >> 192);
    }

    function feeRecipient(address target) internal view returns (address) {
        return address(uint160(word(target, 1)));
    }

    function rewardsRecipient(address target) internal view returns (address) {
        return address(uint160(word(target, 2)));
    }

    /// @notice The pool's books: `Layout` slots 3 to 6.
    function pool(address target) internal view returns (PoolState memory p) {
        uint256 w = word(target, 3);
        p.total = uint64(w);
        p.lockedMargin = uint64(w >> 64);
        p.openMaxProfit = uint64(w >> 128);
        p.totalOwed = uint64(w >> 192);
        w = word(target, 4);
        p.poolFloor = uint64(w);
        p.nextQueueSeq = uint64(w >> 64);
        p.nextRepaySeq = uint64(w >> 128);
        p.openPositions = uint32(w >> 192);
        p.owedPositions = uint32(w >> 224);
        w = word(target, 5);
        p.feesPending = uint64(w);
        p.totalClaimable = uint64(w >> 64);
        p.transferred = uint64(w >> 128);
        p.feesPaid = uint64(w >> 192);
        w = word(target, 6);
        p.seedRecovered = uint64(w);
        p.rewardsWithdrawn = uint64(w >> 64);
    }

    /// @notice The position at place `seq` of the repay queue: `Layout.iouQueue`, root slot 12.
    function iouQueue(address target, uint64 seq) internal view returns (bytes32) {
        return VM.load(target, keccak256(abi.encode(uint256(seq), ROOT + 12)));
    }

    /// @notice `account`'s claimable balance: `Layout.claimable`, root slot 13.
    function claimable(address target, address account) internal view returns (uint64) {
        return uint64(uint256(VM.load(target, keccak256(abi.encode(account, ROOT + 13)))));
    }

    /// @notice The raw word `offset` slots into position `id`: `Layout.positions`, root slot 11.
    function positionWord(address target, bytes32 id, uint256 offset) internal view returns (uint256) {
        bytes32 base = keccak256(abi.encode(id, ROOT + 11));
        return uint256(VM.load(target, bytes32(uint256(base) + offset)));
    }

    /// @notice Position `id`, decoded from its 3 slots.
    function position(address target, bytes32 id) internal view returns (Position memory p) {
        uint256 w = positionWord(target, id, 0);
        p.user = address(uint160(w));
        p.marketIdx = uint16(w >> 160);
        p.side = Side(uint8(w >> 176));
        p.status = Status(uint8(w >> 184));
        p.startTime = uint48(w >> 192);
        p.durationSecs = uint16(w >> 240);
        w = positionWord(target, id, 1);
        p.stake = uint64(w);
        p.entryPrice = int64(uint64(w >> 64));
        p.liqPrice = int64(uint64(w >> 128));
        p.floorBps = uint16(w >> 192);
        p.capBps = uint16(w >> 208);
        p.leverage = uint16(w >> 224);
        w = positionWord(target, id, 2);
        p.owed = uint64(w);
        p.queueSeq = uint64(w >> 64);
    }

    /// @notice The index + 1 stored for the market of feed `marketId` at `leverage` (0 = no such market):
    ///         `Layout.marketIndexPlusOne`, root slot 10, keyed by `keccak256(abi.encode(marketId, leverage))`
    ///         (ADR 0008).
    function marketIndexPlusOne(address target, bytes32 marketId, uint16 leverage) internal view returns (uint16) {
        bytes32 key = keccak256(abi.encode(marketId, leverage));
        return uint16(uint256(VM.load(target, keccak256(abi.encode(key, ROOT + 10)))));
    }

    /// @notice The raw word `offset` slots into market `index`: `Layout.markets`, root slot 9.
    function marketWord(address target, uint16 index, uint256 offset) internal view returns (uint256) {
        bytes32 base = keccak256(abi.encode(uint256(index), ROOT + 9));
        return uint256(VM.load(target, bytes32(uint256(base) + offset)));
    }

    /// @notice Market `index`, decoded from its 8 slots.
    function market(address target, uint16 index) internal view returns (Market memory m) {
        m.marketId = bytes32(marketWord(target, index, 0));
        uint256 w = marketWord(target, index, 1);
        m.enabled = uint8(w) != 0;
        m.paused = uint8(w >> 8) != 0;
        m.priceExponent = int8(uint8(w >> 16));
        m.entryMaxAgeSecs = uint8(w >> 24);
        m.clockSkewSecs = uint8(w >> 32);
        m.floorMinBps = uint16(w >> 40);
        m.floorMaxBps = uint16(w >> 56);
        m.capMinBps = uint16(w >> 72);
        m.capMaxBps = uint16(w >> 88);
        m.maxSellFeeBps = uint16(w >> 104);
        m.sellMinDelaySecs = uint16(w >> 120);
        m.sellCutoffSecs = uint16(w >> 136);
        m.maxExposureBps = uint32(w >> 152);
        m.minStake = uint64(w >> 184);
        w = marketWord(target, index, 2);
        m.maxStake = uint64(w);
        m.maxTotalOwed = uint64(w >> 64);
        m.leverage = uint16(w >> 128);
        for (uint256 i; i < 5; ++i) {
            w = marketWord(target, index, 3 + i);
            m.durations[i].durationSecs = uint16(w);
            m.durations[i].thetaMinE7 = uint32(w >> 16);
            m.durations[i].thetaMaxE7 = uint32(w >> 48);
            m.durations[i].enabled = uint8(w >> 80) != 0;
        }
    }

    /// @notice The circuit breaker: `Layout` slots 7 and 8.
    function breaker(address target) internal view returns (Breaker memory b) {
        uint256 w = word(target, 7);
        b.profitOut = uint64(w);
        b.lossIn = uint64(w >> 64);
        b.windowStart = uint48(w >> 128);
        b.tripped = uint8(w >> 176) != 0;
        b.windowSecs = uint32(w >> 184);
        b.maxNetProfit = uint64(word(target, 8));
    }
}
