// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {OpenOrder, SellOrder, SellTerms} from "../../src/types/OrderTypes.sol";
import {PoolState} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {Defaults} from "../utils/Defaults.sol";
import {Examples} from "../utils/Examples.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";

/// @title Gas_Test
/// @notice What each call the backend makes costs in gas (docs/gas.md): the relayers' `open`, `sell`, `liquidate`
///         and `settle`, and anyone's `repay`, `refundExpired`, `claim` and `sweepFees`. Each benchmark records two
///         numbers in `snapshots/ManicFlashOption.json`: the call's execution gas (`vm.snapshotGasLastFrame`), and the
/// gas of its calldata (`<name> (calldata)`, 16 per non-zero byte and 4 per zero byte). A transaction costs both,
///         plus 21,000. CI fails if a fresh run doesn't match the committed numbers, or if one rises more than 5%
///         above the base branch's (`test/gas/check.py`).
/// @dev The measured call starts from cold state, as a real transaction does: the proxy, the implementation and the
///      token are cooled first (`vm.cool`). Otherwise the bets a test opens just before would leave every slot warm.
///      The worst case is measured throughout:
///      - every bet in a batch is its own user's, so every payout is a transfer of its own;
///      - each user staked their whole balance, so each payout writes an empty token balance;
///      - the token is `MockUSDG`; the real USDG costs about 7,000 more per transfer to a new holder
///        (`test/fork/RealUsdg.t.sol`).
///      The bet is the base bet: a $10 BTC call for a minute at 1000x, θ 3 bp, floor 1.3x, cap 4x.
contract Gas_Test is Settlement_Base_Test {
    /// @dev The snapshot group: `snapshots/ManicFlashOption.json`.
    string internal constant GROUP = "ManicFlashOption";

    /// @dev More free money, so 100 winners at the 4x cap ($30 of profit each) open and are paid at once.
    uint64 internal constant TOP_UP = 5000e6;

    /// @dev A price past every winner's cap: $300 up, 0.36% at 1000x.
    int64 internal constant AT_THE_CAP = Examples.P0 + 300 * Examples.USD;

    /// @dev A price inside every line but below the entry: $1 down, a 1.2% loss at 1000x.
    int64 internal constant AT_A_LOSS = Examples.P0 - Examples.USD;

    /// @dev A price past every call's line: $300 down.
    int64 internal constant PAST_THE_LINE = Examples.P0 - 300 * Examples.USD;

    function setUp() public override {
        super.setUp();
        _fund(users.bob, TOP_UP);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The relayers' calls
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev One bet opened: the order and the stake authorisation checked, the stake pulled, the bet stored.
    function test_Open() external {
        (OpenOrder memory o, uint256 key) = _bettorsOrder(0);
        _mintUsdg(o.user, o.stake);
        bytes memory data = abi.encodeCall(
            flashOption.open, (o, _signOrder(flashOption, key, o), _terms(), _stakeAuth(flashOption, key, o))
        );
        _measure("open", users.opener, data);
        assertEq(LayoutReader.pool(address(flashOption)).openPositions, 1, "the bet is open");
    }

    /// @dev One bet sold at once, $8 up, valued at $12.50 and sold for $12: paid out in one transfer.
    function test_Sell() external {
        (bytes32[] memory ids,) = _openBets(1);
        SellOrder memory s = _sellOrder(ids[0], 12e6);
        SellTerms memory t = _sellTerms(Examples.priceAt(8), 12_500_000, 12e6);
        bytes memory data = abi.encodeCall(flashOption.sell, (s, _signSell(_bettorsKey(0), s), t));
        _measure("sell", users.opener, data);
        _assertEveryBetPaid(1);
    }

    function test_Liquidate1() external {
        _liquidateBatch(1);
    }

    function test_Liquidate10() external {
        _liquidateBatch(10);
    }

    function test_Liquidate50() external {
        _liquidateBatch(50);
    }

    function test_Liquidate100() external {
        _liquidateBatch(100);
    }

    function test_Settle1() external {
        _settleBatch(1, AT_THE_CAP, "settle 1");
    }

    function test_Settle10() external {
        _settleBatch(10, AT_THE_CAP, "settle 10");
    }

    function test_Settle50() external {
        _settleBatch(50, AT_THE_CAP, "settle 50");
    }

    function test_Settle100() external {
        _settleBatch(100, AT_THE_CAP, "settle 100");
    }

    /// @dev The same 100 bets settled at a loss: each still pays part of its stake back, and a loser fee is taken.
    function test_Settle100AtALoss() external {
        _settleBatch(100, AT_A_LOSS, "settle 100 at a loss");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Anyone's calls
    // ---------------------------------------------------------------------------------------------------------------

    function test_Repay1() external {
        _repayBatch(1);
    }

    function test_Repay50() external {
        _repayBatch(50);
    }

    function test_RefundExpired1() external {
        _refundBatch(1);
    }

    function test_RefundExpired50() external {
        _refundBatch(50);
    }

    /// @dev A winner frozen at settle claims the payout that waited, once unfrozen.
    function test_Claim() external {
        (bytes32[] memory ids, uint48 end) = _openBets(1);
        address user = LayoutReader.position(address(flashOption), ids[0]).user;
        vm.prank(usdgAdmin);
        usdg.freeze(user);
        vm.warp(end);
        vm.prank(users.settler);
        flashOption.settle(Defaults.BTC, Defaults.LEVERAGE, AT_THE_CAP, end, ids);
        vm.prank(usdgAdmin);
        usdg.unfreeze(user);
        assertGt(LayoutReader.claimable(address(flashOption), user), 0, "the payout waits");

        _measure("claim", users.eve, abi.encodeCall(flashOption.claim, (user)));
        assertEq(LayoutReader.claimable(address(flashOption), user), 0, "the payout is claimed");
    }

    /// @dev The loser fees of 10 liquidations swept to the fee recipient.
    function test_SweepFees() external {
        (bytes32[] memory ids,) = _openBets(10);
        vm.prank(users.settler);
        flashOption.liquidate(Defaults.BTC, Defaults.LEVERAGE, PAST_THE_LINE, uint48(block.timestamp), ids);
        assertGt(LayoutReader.pool(address(flashOption)).feesPending, 0, "fees to sweep");

        _measure("sweepFees", users.eve, abi.encodeCall(flashOption.sweepFees, ()));
        assertEq(LayoutReader.pool(address(flashOption)).feesPending, 0, "the fees are swept");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Batches
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Opens `n` bets and liquidates them in one batch at once, on a tick past every line.
    function _liquidateBatch(uint256 n) private {
        (bytes32[] memory ids,) = _openBets(n);
        bytes memory data = abi.encodeCall(
            flashOption.liquidate, (Defaults.BTC, Defaults.LEVERAGE, PAST_THE_LINE, uint48(block.timestamp), ids)
        );
        bytes memory returned = _measure(string.concat("liquidate ", vm.toString(n)), users.settler, data);
        assertEq(abi.decode(returned, (uint256)), n, "every bet liquidated");
    }

    /// @dev Opens `n` bets and settles them in one batch at their expiry, at `price`.
    function _settleBatch(uint256 n, int64 price, string memory name) private {
        (bytes32[] memory ids, uint48 end) = _openBets(n);
        vm.warp(end);
        bytes memory data = abi.encodeCall(flashOption.settle, (Defaults.BTC, Defaults.LEVERAGE, price, end, ids));
        bytes memory returned = _measure(name, users.settler, data);
        assertEq(abi.decode(returned, (uint256)), n, "every bet settled");
        _assertEveryBetPaid(n);
    }

    /// @dev On a pool with $1 of free money and the open gate off (`validate` refuses that, so only an upgrade could do
    ///      it: the IOU path is a backstop), `n` winners at the cap are owed; after a top-up, anyone repays all `n` in
    ///      one call.
    function _repayBatch(uint256 n) private {
        _useSmallPool(1e6);
        (bytes32[] memory ids, uint48 end) = _openBets(n);
        vm.warp(end);
        vm.prank(users.settler);
        flashOption.settle(Defaults.BTC, Defaults.LEVERAGE, AT_THE_CAP, end, ids);
        assertEq(LayoutReader.pool(address(flashOption)).owedPositions, n, "every winner owed");
        _fund(users.bob, TOP_UP);

        bytes memory returned =
            _measure(string.concat("repay ", vm.toString(n)), users.eve, abi.encodeCall(flashOption.repay, (n)));
        assertEq(abi.decode(returned, (uint256)), n, "every IOU repaid");
        assertEq(LayoutReader.pool(address(flashOption)).totalOwed, 0, "nobody is owed");
    }

    /// @dev Opens `n` bets the backend never ends; once the refund delay has passed, anyone refunds all `n` in one
    /// call.
    function _refundBatch(uint256 n) private {
        (bytes32[] memory ids, uint48 end) = _openBets(n);
        vm.warp(uint256(end) + Defaults.REFUND_DELAY);
        bytes memory returned = _measure(
            string.concat("refundExpired ", vm.toString(n)), users.eve, abi.encodeCall(flashOption.refundExpired, (ids))
        );
        assertEq(abi.decode(returned, (uint256)), n, "every bet refunded");
        _assertEveryBetPaid(n);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Opens `n` base bets now, each by its own user, who stakes exactly their whole balance.
    /// @return ids The bets' ids.
    /// @return end Their expiry, the same second for all.
    function _openBets(uint256 n) private returns (bytes32[] memory ids, uint48 end) {
        ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            (OpenOrder memory o, uint256 key) = _bettorsOrder(i);
            _open(key, o, _terms());
            ids[i] = o.positionId;
        }
        end = uint48(block.timestamp) + Defaults.DURATION;
    }

    /// @dev Bettor `i`'s order for the base bet, and their key.
    function _bettorsOrder(uint256 i) private returns (OpenOrder memory o, uint256 key) {
        address user;
        (user, key) = makeAddrAndKey(string.concat("bettor ", vm.toString(i)));
        o = _order(user, keccak256(abi.encode("gas", i)));
    }

    /// @dev Bettor `i`'s key.
    function _bettorsKey(uint256 i) private returns (uint256 key) {
        (, key) = makeAddrAndKey(string.concat("bettor ", vm.toString(i)));
    }

    /// @dev Calls the proxy with `data` as `caller`, from cold state, and records the call's execution gas as `name`
    ///      and its calldata's gas as `name (calldata)`. The call must succeed.
    /// @return returned What the call returned.
    function _measure(string memory name, address caller, bytes memory data) private returns (bytes memory returned) {
        vm.cool(address(flashOption));
        vm.cool(address(implementation));
        vm.cool(address(usdg));
        vm.prank(caller);
        bool ok;
        (ok, returned) = address(flashOption).call(data);
        vm.snapshotGasLastFrame(GROUP, name);
        assertTrue(ok, string.concat(name, " reverted: ", vm.toString(returned)));
        vm.snapshotValue(GROUP, string.concat(name, " (calldata)"), _calldataGas(data));
    }

    /// @dev Every bet the call ended was paid at once: none waits in `claimable`, nobody is owed.
    function _assertEveryBetPaid(uint256 n) private view {
        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.totalClaimable, 0, "no payout waits");
        assertEq(pool.totalOwed, 0, "nobody is owed");
        assertEq(pool.openPositions, 0, string.concat("all ", vm.toString(n), " ended"));
    }

    /// @dev The gas of `data` as calldata (EIP-2028): 16 per non-zero byte, 4 per zero byte.
    function _calldataGas(bytes memory data) private pure returns (uint256 gas) {
        for (uint256 i; i < data.length; ++i) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }
}
