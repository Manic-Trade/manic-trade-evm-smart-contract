// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Status} from "../../../src/types/StorageTypes.sol";

/// @title FlashOptionStore
/// @notice The ghost state the invariant handlers share (docs/ARCHITECTURE.md §12, docs/CONVENTIONS.md §9): BTC's
///         price, every bet the handlers opened with what its order and terms said, how many bets each leverage's
///         market opened, ended and owed, and the first breach that any check run during a call found.
/// @dev Only the handlers write here, and the invariant test reads it after every call. It is not a fuzz target: the
///      test names its handlers with `targetContract`, so the fuzzer calls nothing else.
contract FlashOptionStore {
    /// @dev What the handlers know about one bet.
    struct Bet {
        address user; // the bettor, whom every payout of the bet must reach
        uint64 stake; // the stake the order signed
        uint16 capBps; // the cap the terms set
        uint16 leverage; // its market's leverage, which the order signed
        uint48 endTime; // its expiry second
        Status lastStatus; // its status after the last call
        uint64 received; // what its user has been paid for it so far, pushed or kept claimable
    }

    /// @notice BTC's price now, at its exponent: the tick every handler prices with, on all of BTC's markets.
    int64 public price;

    /// @notice Tokens sent straight to the contract, outside `fund`. The books never count them.
    uint256 public donations;

    /// @notice Whether the breaker's limit was switched on or lowered since the last call that counted (or reset it).
    ///         Until the next count, the window's net profit may already sit above the new limit, untripped (§12 #11).
    bool public limitTightened;

    /// @notice Whether a bet was ever opened while the open gate let open bets' max profit exceed free money: the gate
    ///         off, or above 10,000 bps. §12 #5 holds only while this is false.
    bool public openedBeyondFullCover;

    /// @notice Whether the campaign keeps every market's open gate off (`SmallPool_Invariant_Test`): `validate` refuses
    ///         the gate off (ADR 0009), so the gate is switched off in storage, as only an upgrade could, and again
    ///         after each `configure`. Only such a campaign can open a bet beyond full cover.
    bool public gateKeptOff;

    /// @notice How many bets each leverage's market opened, how many of them ended (closed or owed), and how many were
    ///         owed as IOUs: what `SmallPool_Invariant_Test.test_EveryActionDoesItsWork` checks each market did.
    mapping(uint16 leverage => uint256) public openedAt;
    mapping(uint16 leverage => uint256) public endedAt;
    mapping(uint16 leverage => uint256) public owedAt;

    bytes32[] private _ids;
    mapping(bytes32 id => Bet) private _bets;
    uint256 private _nonce;

    /// @dev The first breach of each invariant, by its §12 number, and the numbers in the order they were breached.
    mapping(uint256 invariant => string) private _breaches;
    uint256[] private _breached;

    constructor(int64 startPrice) {
        price = startPrice;
    }

    function setPrice(int64 newPrice) external {
        price = newPrice;
    }

    /// @notice A position id never used before: also the order's nonce and its stake authorisation's.
    function newId() external returns (bytes32) {
        return keccak256(abi.encode("invariant bet", ++_nonce));
    }

    /// @notice Records a bet the contract just opened, on the market of `leverage`.
    function addBet(bytes32 id, address user, uint64 stake, uint16 capBps, uint16 leverage, uint48 endTime) external {
        _ids.push(id);
        _bets[id] = Bet({
            user: user,
            stake: stake,
            capBps: capBps,
            leverage: leverage,
            endTime: endTime,
            lastStatus: Status.Open,
            received: 0
        });
        ++openedAt[leverage];
    }

    function setLimitTightened(bool tightened) external {
        limitTightened = tightened;
    }

    function addDonation(uint256 amount) external {
        donations += amount;
    }

    function setOpenedBeyondFullCover() external {
        openedBeyondFullCover = true;
    }

    function setGateKeptOff() external {
        gateKeptOff = true;
    }

    /// @notice Records the bet's status after a call, and counts it for its market when it ends or becomes an IOU.
    function setLastStatus(bytes32 id, Status status) external {
        Bet storage b = _bets[id];
        if (b.lastStatus == Status.Open && status != Status.Open) ++endedAt[b.leverage];
        if (status == Status.Owed && b.lastStatus != Status.Owed) ++owedAt[b.leverage];
        b.lastStatus = status;
    }

    function addReceived(bytes32 id, uint64 amount) external {
        _bets[id].received += amount;
    }

    /// @notice Records the first breach of invariant `invariant`; later ones of the same invariant are dropped.
    function recordBreach(uint256 invariant, string calldata why) external {
        if (bytes(_breaches[invariant]).length > 0) return;
        _breaches[invariant] = why;
        _breached.push(invariant);
    }

    function betCount() external view returns (uint256) {
        return _ids.length;
    }

    function idAt(uint256 index) external view returns (bytes32) {
        return _ids[index];
    }

    function bet(bytes32 id) external view returns (Bet memory) {
        return _bets[id];
    }

    function lastStatus(bytes32 id) external view returns (Status) {
        return _bets[id].lastStatus;
    }

    /// @notice The first breach any check found during a call, or "" while there is none.
    function firstBreach() external view returns (string memory) {
        return _breached.length == 0 ? "" : _breaches[_breached[0]];
    }
}
