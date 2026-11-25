// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {ManicFlashOption} from "../../../src/ManicFlashOption.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {Breaker, Market, PoolState, Position, Status} from "../../../src/types/StorageTypes.sol";
import {MockUSDG} from "../../mocks/MockUSDG.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";
import {Users} from "../../utils/Users.sol";
import {FlashOptionStore} from "../stores/FlashOptionStore.sol";

/// @notice Everything a handler works with, which the invariant test passes to each handler's constructor.
struct HandlerSetup {
    ManicFlashOption flashOption;
    MockUSDG usdg;
    address usdgAdmin; // mints, freezes and pauses the token
    FlashOptionStore store;
    Users users; // the role holders and the recipients
    address[] bettors; // the users who bet
    uint256[] bettorKeys; // their signing keys, in the same order
    address stranger; // holds no role and no token, and must never receive any
    address funder; // funds the pool
}

/// @title BaseHandler
/// @notice What every invariant handler shares (docs/CONVENTIONS.md §9): the contract and its token, BTC's three
///         markets (1000x, 500x and 100x, on one pool), the actors, the per-action call counters of the security
///         checklist's TEST-1, the check of an expected refusal, and the checks run around every call: where the money
///         went (§12 #9, #10), that no status moved back (#8), and what the payout circuit breaker did (#11).
/// @dev Every action is `instrumented`: it counts the call, and its body must end in exactly one outcome.
///      - Done: the call went through, as the handler expected.
///      - Refused: the handler expected a refusal, and the contract refused with exactly the expected error. A success,
///        or any other error, is recorded as a breach of the invariant the refusal protects.
///      - Skipped: there was nothing to act on, such as no bet to settle.
///      A path that ends without an outcome reverts. So does any call the handler expects to go through that the
///      contract refuses. The invariant runs set `fail_on_revert`, so either one fails the run instead of letting it
///      pass with an action that has quietly stopped working.
///
///      Around every call, `instrumented` also checks:
///      - the money: what each known account holds (its tokens plus what it may claim) changes by exactly what the
///        contract's logs say it was paid. A bet's payout reaches its own user, the fees reach the fee recipient, a
///        withdrawal reaches its recipient, and nobody else gains a unit. Each bet's payouts add up in the store;
///      - the statuses: every bet's status moved forward or not at all (None → Open → (Owed →) Closed);
///      - the breaker: nothing opened or sold while it was tripped, and it tripped only on a call that counted
///        profit past its limit.
abstract contract BaseHandler is CommonBase, StdCheats, StdUtils {
    enum Outcome {
        None,
        Done,
        Refused,
        Skipped
    }

    ManicFlashOption internal immutable flashOption;
    MockUSDG internal immutable usdg;
    address internal immutable usdgAdmin;
    FlashOptionStore internal immutable store;
    address internal immutable stranger;
    address internal immutable funder;
    Users internal users;
    address[] internal bettors;
    uint256[] internal bettorKeys;
    /// @dev Every account that may hold the token or receive from the contract, each once: the money check watches
    ///      them all.
    address[] internal known;

    /// @notice How many times each action was called, and how each call ended.
    mapping(string action => uint256) public calls;
    mapping(string action => uint256) public done;
    mapping(string action => uint256) public refused;
    mapping(string action => uint256) public skipped;

    Outcome private _outcome;
    /// @dev The current call's state, kept in storage rather than in the modifier, whose locals would share the stack
    ///      with every action's: what the known accounts held and the breaker when it started, what the contract's logs
    ///      have paid each account so far, and whether a bet opened or sold.
    uint256[] private _heldBefore;
    uint256[] private _paid;
    Breaker private _breakerBefore;
    bool private _openedOrSold;
    uint256 private _trips;

    /// @dev Counts the call of `action` and how it ended, and runs the checks around it.
    modifier instrumented(string memory action) {
        _beforeCall(action);
        _;
        _afterCall(action);
    }

    constructor(HandlerSetup memory s) {
        flashOption = s.flashOption;
        usdg = s.usdg;
        usdgAdmin = s.usdgAdmin;
        store = s.store;
        stranger = s.stranger;
        funder = s.funder;
        users = s.users;
        bettors = s.bettors;
        bettorKeys = s.bettorKeys;
        address[11] memory named = [
            s.users.admin,
            s.users.upgrader,
            s.users.operator,
            s.users.guardian,
            s.users.opener,
            s.users.settler,
            s.users.feeRecipient,
            s.users.rewardsRecipient,
            s.users.alice,
            s.users.bob,
            s.users.eve
        ];
        for (uint256 i; i < named.length; ++i) {
            _know(named[i]);
        }
        for (uint256 i; i < s.bettors.length; ++i) {
            _know(s.bettors[i]);
        }
        _know(s.stranger);
        _know(s.funder);
    }

    /// @dev Ends the call with `result`.
    function _finish(Outcome result) internal {
        _outcome = result;
    }

    function _done() internal {
        _outcome = Outcome.Done;
    }

    function _refuse() internal {
        _outcome = Outcome.Refused;
    }

    function _skip() internal {
        _outcome = Outcome.Skipped;
    }

    /// @dev Checks a call the handler expected the contract to refuse with `expected`. The call went through (`ok`),
    ///      or was refused with `reason`; anything but `expected` is a breach of invariant `invariant` (§12).
    function _checkRefusal(
        uint256 invariant,
        string memory action,
        bool ok,
        bytes memory reason,
        bytes memory expected
    )
        internal
    {
        if (ok) {
            store.recordBreach(invariant, string.concat(action, ": went through where it had to be refused"));
        } else if (keccak256(reason) != keccak256(expected)) {
            store.recordBreach(
                invariant,
                string.concat(action, ": refused with ", vm.toString(reason), " instead of ", vm.toString(expected))
            );
        }
    }

    /// @dev A number in `[lo, hi]` drawn from `seed`; each `salt` draws an independent one.
    function _pick(uint256 seed, uint256 salt, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return _bound(uint256(keccak256(abi.encode(seed, salt))), lo, hi);
    }

    /// @dev Any known account: a bettor, a role holder, a recipient, the funder or the stranger.
    function _anyone(uint256 seed) internal view returns (address) {
        return known[_pick(seed, 9, 0, known.length - 1)];
    }

    function _mint(address to, uint256 amount) internal {
        vm.prank(usdgAdmin);
        usdg.mint(to, amount);
    }

    /// @dev The leverage of one of BTC's three markets, picked by `i`: 1000x, 500x or 100x.
    function _pickLeverage(uint256 i) internal pure returns (uint16) {
        uint16[3] memory leverages = [uint16(1000), 500, 100];
        return leverages[i % 3];
    }

    /// @dev BTC's market at `marketLeverage`, as stored.
    function _market(uint16 marketLeverage) internal view returns (Market memory) {
        uint16 indexPlusOne = LayoutReader.marketIndexPlusOne(address(flashOption), Defaults.BTC, marketLeverage);
        return LayoutReader.market(address(flashOption), indexPlusOne - 1);
    }

    /// @dev The market `p` was opened in, as stored.
    function _marketOf(Position memory p) internal view returns (Market memory) {
        return LayoutReader.market(address(flashOption), p.marketIdx);
    }

    function _pool() internal view returns (PoolState memory) {
        return LayoutReader.pool(address(flashOption));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The checks run around every call
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Counts the call and notes what the checks after it compare against; from here, the logs are recorded.
    function _beforeCall(string memory action) private {
        ++calls[action];
        _outcome = Outcome.None;
        _heldBefore = _held();
        _paid = new uint256[](known.length);
        _breakerBefore = LayoutReader.breaker(address(flashOption));
        _openedOrSold = false;
        _trips = 0;
        vm.recordLogs();
    }

    /// @dev Takes in the call's last logs, runs the checks, then counts how it ended. A path that said nothing reverts.
    function _afterCall(string memory action) private {
        _absorb(action, vm.getRecordedLogs());
        _checkMoney(action);
        _checkStatuses(action);
        _checkBreaker(action);
        if (_outcome == Outcome.Done) ++done[action];
        else if (_outcome == Outcome.Refused) ++refused[action];
        else if (_outcome == Outcome.Skipped) ++skipped[action];
        else revert(string.concat(action, ": ended without an outcome"));
    }

    /// @dev Makes, as `caller`, a call the handler expects the contract to refuse, and returns how it went. Foundry
    ///      records a log when it is emitted, even in a call that then reverts, so the logs before this call are taken
    ///      in first and those of a refused call are dropped: a reverted call changed nothing.
    function _attempt(
        string memory action,
        address caller,
        bytes memory data
    )
        internal
        returns (bool ok, bytes memory reason)
    {
        _absorb(action, vm.getRecordedLogs());
        vm.prank(caller);
        (ok, reason) = address(flashOption).call(data);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        if (ok) _absorb(action, logs);
    }

    /// @dev What each known account holds: its tokens, plus what the contract keeps for it to claim.
    function _held() internal view returns (uint256[] memory held) {
        held = new uint256[](known.length);
        for (uint256 i; i < known.length; ++i) {
            held[i] = usdg.balanceOf(known[i]) + LayoutReader.claimable(address(flashOption), known[i]);
        }
    }

    /// @dev Takes in the contract's `logs`. Each payment adds to what its account was paid in this call and to what
    ///      its bet's user has received for it (§12 #9); a payment to an account the handlers don't know is a breach
    ///      of #10. A bet opened or sold is noted for the breaker's check, and each trip is checked as it comes (#11).
    function _absorb(string memory action, VmSafe.Log[] memory logs) private {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(flashOption)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == Events.PositionOpened.selector || topic == Events.PositionSold.selector) _openedOrSold = true;
            if (topic == Events.CircuitBreakerTripped.selector) _checkTrip(action, logs[i]);
            (bytes32 id, address to, uint256 amount) = _payment(logs[i]);
            if (to == address(0)) continue;
            uint256 k = _indexOf(to);
            if (k == known.length) {
                store.recordBreach(10, string.concat(action, ": paid an unknown account ", vm.toString(to)));
                continue;
            }
            _paid[k] += amount;
            // casting to uint64 is safe: every payment is a uint64 field, or a difference of two
            if (id != bytes32(0)) store.addReceived(id, uint64(amount));
        }
    }

    /// @dev §12 #10: every known account's holdings changed by exactly what the contract's logs say it was paid.
    function _checkMoney(string memory action) private {
        uint256[] memory held = _held();
        for (uint256 k; k < known.length; ++k) {
            if (held[k] == _heldBefore[k] + _paid[k]) continue;
            store.recordBreach(
                10,
                string.concat(
                    action,
                    ": ",
                    vm.toString(known[k]),
                    " holds ",
                    vm.toString(held[k]),
                    " after holding ",
                    vm.toString(_heldBefore[k]),
                    " and being paid ",
                    vm.toString(_paid[k])
                )
            );
        }
    }

    /// @dev §12 #8: every bet's status moved forward (None, Open, maybe Owed, Closed) or not at all. Closed bets are
    ///      watched too, so a tombstone that came back to life is caught.
    function _checkStatuses(string memory action) internal {
        uint256 n = store.betCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = store.idAt(i);
            Status was = store.lastStatus(id);
            Status status = LayoutReader.position(address(flashOption), id).status;
            if (status == was) continue;
            bool forward = (was == Status.Open && (status == Status.Owed || status == Status.Closed))
                || (was == Status.Owed && status == Status.Closed);
            if (!forward) {
                store.recordBreach(
                    8,
                    string.concat(
                        action,
                        ": bet ",
                        vm.toString(id),
                        " went from status ",
                        vm.toString(uint256(was)),
                        " to ",
                        vm.toString(uint256(status))
                    )
                );
            }
            store.setLastStatus(id, status);
        }
    }

    /// @dev §12 #11: a trip happens only on the change, with a limit set, once the window's profit out beats its
    ///      losses kept by more than the limit. `CircuitBreakerTripped` carries the window's counters at that moment;
    ///      the limit can't change within a call.
    function _checkTrip(string memory action, VmSafe.Log memory log) private {
        ++_trips;
        uint256 limit = LayoutReader.breaker(address(flashOption)).maxNetProfit;
        bool pastLimit = limit > 0 && _word(log.data, 0) > _word(log.data, 1) + limit;
        if (_breakerBefore.tripped || _trips > 1 || !pastLimit) {
            store.recordBreach(11, string.concat(action, ": tripped the breaker without counting past its limit"));
        }
    }

    /// @dev §12 #11, around one call:
    ///      - while the breaker was tripped, nothing opened or sold;
    ///      - a breaker that became tripped logged its trip (each trip is checked in `_checkTrip`).
    ///      A call that counted (the counters or the window moved) also clears the store's `limitTightened`: from here,
    ///      an untripped breaker with a limit must sit at or under it.
    function _checkBreaker(string memory action) private {
        Breaker memory before = _breakerBefore;
        if (before.tripped && _openedOrSold) {
            store.recordBreach(11, string.concat(action, ": opened or sold while the breaker was tripped"));
        }
        Breaker memory b = LayoutReader.breaker(address(flashOption));
        if (!before.tripped && b.tripped && _trips == 0) {
            store.recordBreach(11, string.concat(action, ": the breaker tripped without logging it"));
        }
        if (b.profitOut != before.profitOut || b.lossIn != before.lossIn || b.windowStart != before.windowStart) {
            store.setLimitTightened(false);
        }
    }

    /// @dev The payment a log of the contract records: the bet (0 for a fee sweep or a withdrawal), the account paid
    ///      and the amount, both pushed and kept claimable. Any other log returns the zero address.
    function _payment(VmSafe.Log memory log) internal pure returns (bytes32 id, address to, uint256 amount) {
        bytes32 topic = log.topics[0];
        if (topic == Events.PositionSettled.selector) {
            // `paidNow` is what the user gets now: the stake back and the profit paid, less the winner fee.
            return (log.topics[1], _address(log.topics[2]), _word(log.data, 6));
        }
        if (topic == Events.PositionSold.selector) {
            // The sale amount, less the winner fee.
            return (log.topics[1], _address(log.topics[2]), _word(log.data, 6) - _word(log.data, 8));
        }
        if (topic == Events.OwedRepaid.selector) {
            // The amount repaid, less the winner fee.
            return (log.topics[1], _address(log.topics[2]), _word(log.data, 1) - _word(log.data, 2));
        }
        if (topic == Events.PositionRefunded.selector) {
            return (log.topics[1], _address(log.topics[2]), _word(log.data, 0));
        }
        if (topic == Events.FeesSwept.selector) return (bytes32(0), _address(log.topics[1]), _word(log.data, 0));
        if (topic == Events.PoolWithdrawn.selector) return (bytes32(0), _address(log.topics[1]), _word(log.data, 1));
    }

    function _indexOf(address account) internal view returns (uint256 k) {
        for (k = 0; k < known.length; ++k) {
            if (known[k] == account) return k;
        }
    }

    function _know(address account) private {
        if (_indexOf(account) == known.length) known.push(account);
    }

    /// @dev Word `i` of an event's data: its `i`-th field when every field is a static type.
    function _word(bytes memory data, uint256 i) private pure returns (uint256 w) {
        assembly ("memory-safe") {
            w := mload(add(data, mul(add(i, 1), 32)))
        }
    }

    function _address(bytes32 topic) private pure returns (address) {
        return address(uint160(uint256(topic)));
    }
}
