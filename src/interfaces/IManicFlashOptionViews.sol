// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OpenOrder, SellOrder} from "../types/OrderTypes.sol";
import {Breaker, Market, PoolState, Position} from "../types/StorageTypes.sol";

/// @title IManicFlashOptionViews
/// @author Manic
/// @notice The contract's read-only functions (docs/ARCHITECTURE.md §8.9): the positions, the markets, the pool's
///         books, the repay queue, the circuit breaker and the settings, and the EIP-712 hash helpers.
/// @dev Every getter that reads the contract's storage reverts with `ReentrancyGuardReentrantCall` while one of the
///      contract's state-changing functions is running, so a contract that reads them from inside a call into this one
///      (a token callback) can never see half-updated books (read-only reentrancy, §15 rule 12). Off-chain reads and
///      ordinary calls are never affected.
/// @custom:security-contact See SECURITY.md
interface IManicFlashOptionViews {
    /// @notice The EIP-712 digest a user signs to open a position, so the backend can check its own encoding against
    ///         the contract's.
    /// @dev The order's struct hash under this contract's domain: the name "Manic Flash Option", version "1", the chain
    ///      id and this proxy's address. The same order gives another digest on another chain or another deployment,
    ///      so a signature can never be replayed there.
    /// @param o The order.
    /// @return The digest the user's signature must sign.
    function hashOpenOrder(OpenOrder calldata o) external view returns (bytes32);

    /// @notice The EIP-712 digest a position's user signs to sell it early.
    /// @dev The same as `hashOpenOrder`, for a `SellOrder`.
    /// @param s The order.
    /// @return The digest the user's signature must sign.
    function hashSellOrder(SellOrder calldata s) external view returns (bytes32);

    /// @notice A position as stored, with its expiry second and its cap price.
    /// @dev An id that was never used returns an empty record, `status` `None`: that is how to tell an id is free.
    ///      A closed position keeps only its first slot (the user, the market, the side, the status, the start and the
    ///      duration); its stake, prices, floor and cap read 0, and so does its cap price. An IOU keeps its terms and
    ///      also reads `owed` and `queueSeq`. The cap price isn't stored: it is recomputed from the entry, the side,
    ///      the cap and the leverage of the bet's market (`LeverageMath.capLine`), which gives the value
    ///      {PositionOpened} reported.
    /// @param positionId The position's id.
    /// @return position The stored position.
    /// @return endTime Its expiry second: `startTime + durationSecs`.
    /// @return capPrice The cap line, rounded toward the entry (the payout may reach its cap one price unit beyond
    ///         it); 0 when its terms are cleared.
    function getPosition(bytes32 positionId)
        external
        view
        returns (Position memory position, uint48 endTime, int64 capPrice);

    /// @notice A market's settings, its leverage included.
    /// @dev Reverts `UnknownMarket` for a feed and leverage that no market has.
    /// @param marketId The market's Pyth feed id.
    /// @param leverage The market's leverage.
    /// @return The market.
    function getMarket(bytes32 marketId, uint16 leverage) external view returns (Market memory);

    /// @notice The key of the market at `index`, the index positions record: its feed and its leverage. Markets are
    ///         numbered from 0 in the order they were created.
    /// @dev Reverts `UnknownMarket` for an index at or above `marketCount()`.
    /// @param index The market's index.
    /// @return marketId The market's Pyth feed id.
    /// @return leverage The market's leverage.
    function marketIdAt(uint16 index) external view returns (bytes32 marketId, uint16 leverage);

    /// @notice How many markets have been created; their indexes run from 0 to this less one.
    /// @return The number of markets.
    function marketCount() external view returns (uint16);

    /// @notice The pool's books: every field of `PoolState`.
    /// @dev The contract's token balance always covers `total + feesPending + totalClaimable` (§9).
    /// @return The books.
    function getPool() external view returns (PoolState memory);

    /// @notice The pool's free money: its total less the stakes of open bets. What new bets' max profit, repayments
    ///         and withdrawals are measured against.
    /// @return `total - lockedMargin`.
    function freeMoney() external view returns (uint64);

    /// @notice What waits for `account` to claim: payouts whose transfer the token refused.
    /// @param account The account.
    /// @return Its claimable balance, which `claim(account)` pays.
    function claimableOf(address account) external view returns (uint64);

    /// @notice The head of the repay queue: the IOU `repay` pays next.
    /// @dev With nobody owed, it returns the next place and no position: `(nextRepaySeq, 0, 0)`.
    /// @return queueSeq The head's place in the queue.
    /// @return positionId The head's position, or 0 if the queue is empty.
    /// @return owed What the head is still owed, or 0 if the queue is empty.
    function queueHead() external view returns (uint64 queueSeq, bytes32 positionId, uint64 owed);

    /// @notice The payout circuit breaker: its window, its counters, its limit and whether it has tripped (§8.11).
    /// @return The breaker.
    function getBreaker() external view returns (Breaker memory);

    /// @notice The stablecoin the pool holds and pays in (USDG), set at initialisation.
    /// @return The token.
    function token() external view returns (IERC20);

    /// @notice Whether the guardian or the operator has halted the contract: no bet opens, sells or ends, and no IOU
    ///         is repaid, until the operator releases it (§8.10).
    /// @return True while halted.
    function halted() external view returns (bool);

    /// @notice How long after its expiry anyone may refund a position that was never ended (the safety refund).
    /// @return The delay in seconds; 0 when the refund is switched off.
    function refundDelaySecs() external view returns (uint48);

    /// @notice Where money leaves the pool to.
    /// @return feeRecipient Receives swept fees and seed recovery.
    /// @return rewardsRecipient Receives rewards withdrawals.
    function recipients() external view returns (address feeRecipient, address rewardsRecipient);

    /// @notice The version of the implementation behind the proxy.
    /// @dev Each upgrade raises it, so a script can check which code a proxy runs.
    /// @return The version string, `"1.0.0"` for the first release.
    function version() external pure returns (string memory);
}
