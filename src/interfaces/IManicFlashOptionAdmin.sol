// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ConfigParams, InitParams} from "../types/ParamTypes.sol";

/// @title IManicFlashOptionAdmin
/// @author Manic
/// @notice The contract's setup and admin functions (docs/ARCHITECTURE.md §8.1, §8.9b). None of them moves money.
///         The ones that could redirect it (market creation, the floor, the recipients) need the admin, which is the
///         48-hour timelock on mainnet.
/// @dev Access control comes first in every function, then its checks in the order listed. `initialize` is
///      implemented by `ManicFlashOption`, the rest by `AdminModule`.
/// @custom:security-contact See SECURITY.md
interface IManicFlashOptionAdmin {
    /// @notice Sets the proxy up: grants every role and sets the token, the pool floor, the fee and rewards
    ///         recipients, the safety refund delay and the circuit breaker. It runs once, inside the transaction that
    ///         deploys the proxy, so nobody can call it first.
    /// @dev Emits OpenZeppelin's {RoleGranted} for each role holder, then {PoolFloorUpdated}, {RecipientsUpdated},
    ///      {RefundDelayUpdated} and {CircuitBreakerUpdated}, then OpenZeppelin's {Initialized}. These are the events
    ///      the matching admin setters emit, so an indexer sees the initial settings the same way as later changes.
    ///
    /// Requirements (in check order):
    /// - Called once, through the proxy. Never on the implementation (`InvalidInitialization`).
    /// - Every address is non-zero (`ZeroAddress`), checked in field order: admin, upgrader, operator, guardian, each
    ///   opener, each settler, token, fee recipient, rewards recipient.
    /// - The token has 6 to 9 decimals, so every amount fits a `uint64` (`InvalidTokenDecimals`).
    /// - The pool floor is at least 500 whole tokens (`InvalidLeverageParams`).
    /// - The refund delay is 0, meaning off, or at least 1 hour (`InvalidRefundDelay`).
    /// - The circuit breaker's window is 60 to 86,400 seconds (`InvalidBreakerParams`).
    ///
    /// @param p Every setting, in one struct (src/types/ParamTypes.sol).
    function initialize(InitParams calldata p) external;

    /// @notice Creates a market for a price feed at one leverage, switched off. One feed can have a market per
    ///         leverage (BTC at 1000x, 500x and 100x), each with its own settings (ADR 0008). The operator switches it
    ///         on with `setConfig` once its settings are checked.
    /// @dev The market is stored at the next index with its leverage and every setting of `p`, unpaused. The pair
    ///      (`marketId`, `leverage`) is its key, so neither ever changes. It is always created switched off, so
    ///      `p.enabled` must be false. Emits {MarketCreated}, then {ConfigUpdated} with the settings as stored.
    ///
    /// Requirements (in check order):
    /// - The caller holds `DEFAULT_ADMIN_ROLE` (`AccessControlUnauthorizedAccount`).
    /// - `marketId` is not zero (`InvalidLeverageParams`).
    /// - No market has this feed and leverage yet (`MarketExists`).
    /// - `priceExponent` is -18 to 0 (`InvalidLeverageParams`).
    /// - `p.enabled` is false (`InvalidLeverageParams`).
    /// - The leverage is 1x to 10,000x, and the settings pass `ConfigLib.validate` at it (`InvalidLeverageParams`).
    /// - Fewer than 65,535 markets exist (`MathOverflow`).
    ///
    /// @param marketId The price feed's Pyth id.
    /// @param leverage The market's leverage, 1x to 10,000x (1000 is 1000x). With `marketId`, it identifies the market
    ///        from now on.
    /// @param priceExponent The feed's price exponent (BTC: -8), fixed for the market's life.
    /// @param p The market's settings.
    function createMarket(bytes32 marketId, uint16 leverage, int8 priceExponent, ConfigParams calldata p) external;

    /// @notice Replaces every setting of a market at once, `enabled` included: this is also how a market is switched
    ///         on and off.
    /// @dev The market's id, leverage, pause and price exponent never change. Positions already open keep the terms
    ///      they were opened with. Emits {ConfigUpdated}.
    ///
    /// Requirements (in check order):
    /// - The caller holds `OPERATOR_ROLE` (`AccessControlUnauthorizedAccount`).
    /// - The market exists at this feed and leverage (`UnknownMarket`).
    /// - The settings pass `ConfigLib.validate` at the market's leverage (`InvalidLeverageParams`).
    ///
    /// @param marketId The market's Pyth feed id.
    /// @param leverage The market's leverage.
    /// @param p The market's new settings.
    function setConfig(bytes32 marketId, uint16 leverage, ConfigParams calldata p) external;

    /// @notice Pauses or unpauses one market. A paused market blocks only opens and sales: liquidations, settlements,
    ///         repayments and refunds go on, so open bets still end and IOUs are still paid (§8.10).
    /// @dev Pausing a market that is already paused succeeds and emits again. Emits {PauseChanged}.
    ///
    /// Requirements (in check order):
    /// - Pausing: the caller holds `GUARDIAN_ROLE` or `OPERATOR_ROLE` (`AccessControlUnauthorizedAccount`, naming
    ///   `GUARDIAN_ROLE`).
    /// - Unpausing: the caller holds `OPERATOR_ROLE` (`OnlyOperatorCanUnpause`).
    /// - The market exists at this feed and leverage (`UnknownMarket`).
    ///
    /// @param marketId The market's Pyth feed id.
    /// @param leverage The market's leverage: each leverage of a feed is paused on its own. The guardian's
    ///        `setHalted` stops every market at once.
    /// @param paused Whether the market should be paused.
    function setPaused(bytes32 marketId, uint16 leverage, bool paused) external;

    /// @notice Halts or resumes the whole contract: the global stop. While halted, nobody can open, sell, liquidate,
    ///         settle or repay; refunds, funding, withdrawals, claims, fee sweeps and admin work go on (§8.10).
    /// @dev Halting again succeeds and emits again. Emits {HaltChanged}.
    ///
    /// Requirements (in check order):
    /// - Halting: the caller holds `GUARDIAN_ROLE` or `OPERATOR_ROLE` (`AccessControlUnauthorizedAccount`, naming
    ///   `GUARDIAN_ROLE`).
    /// - Resuming: the caller holds `OPERATOR_ROLE` (`OnlyOperatorCanUnhalt`).
    ///
    /// @param halted Whether the contract should be halted.
    function setHalted(bool halted) external;

    /// @notice Sets the pool floor: free money below which no loser fee is taken and no withdrawal may go.
    /// @dev Emits {PoolFloorUpdated}.
    ///
    /// Requirements (in check order):
    /// - The caller holds `DEFAULT_ADMIN_ROLE` (`AccessControlUnauthorizedAccount`).
    /// - The floor is at least 500 whole tokens (`InvalidLeverageParams`).
    ///
    /// @param poolFloor The new floor, in base units of the token.
    function setPoolFloor(uint64 poolFloor) external;

    /// @notice Sets where swept fees and seed recovery go, and where rewards withdrawals go.
    /// @dev Emits {RecipientsUpdated}.
    ///
    /// Requirements (in check order):
    /// - The caller holds `DEFAULT_ADMIN_ROLE` (`AccessControlUnauthorizedAccount`).
    /// - Neither address is zero (`ZeroAddress`).
    ///
    /// @param feeRecipient Receives swept fees and seed recovery.
    /// @param rewardsRecipient Receives rewards withdrawals.
    function setRecipients(address feeRecipient, address rewardsRecipient) external;

    /// @notice Sets how long after its expiry anyone may refund a position the backend never ended (the safety
    ///         refund, `refundExpired`). 0 switches the refund off.
    /// @dev It applies to positions already open, because `refundExpired` reads it when it runs. A shorter delay lets
    ///      users take their stakes back sooner, before the backend may have ended their bets; a longer one, or 0,
    ///      keeps them waiting if the backend stops. Both are the admin's call: the 48-hour timelock on mainnet.
    ///      Emits {RefundDelayUpdated}, also when the delay doesn't change.
    ///
    /// Requirements (in check order):
    /// - The caller holds `DEFAULT_ADMIN_ROLE` (`AccessControlUnauthorizedAccount`).
    /// - The delay is 0, meaning off, or at least 1 hour (`InvalidRefundDelay`), as in `initialize`.
    ///
    /// @param refundDelaySecs The new delay after expiry, in seconds (24 hours at launch).
    function setRefundDelay(uint48 refundDelaySecs) external;

    /// @notice Sets the payout circuit breaker's limit and window: the net profit users may take out of the pool in
    ///         one window before `open` and `sell` stop (docs/ARCHITECTURE.md §8.11). A limit of 0 switches it off.
    /// @dev Raising the limit or switching the breaker off weakens a guard against a stolen relayer key, so it is the
    ///      admin's call: the 48-hour timelock on mainnet. It leaves the counters, the window start and a trip alone:
    ///      switching the breaker off doesn't clear a trip, and the operator's `resetBreaker` does. A new window
    ///      length applies to the current window at once. Emits {CircuitBreakerUpdated}, also when nothing changes.
    ///
    /// Requirements (in check order):
    /// - The caller holds `DEFAULT_ADMIN_ROLE` (`AccessControlUnauthorizedAccount`).
    /// - The window is 60 to 86,400 seconds (`InvalidBreakerParams`), as in `initialize`.
    ///
    /// @param maxNetProfit The net profit allowed out per window, in base units of the token; 0 switches it off.
    /// @param windowSecs The window's length, in seconds.
    function setBreaker(uint64 maxNetProfit, uint32 windowSecs) external;

    /// @notice Clears a trip of the payout circuit breaker, so `open` and `sell` work again, and starts a fresh
    ///         window. The operator calls it once they have checked what tripped it.
    /// @dev Both counters go to zero and the window starts at this block's second; the limit and the window's length
    ///      stay. It may be called at any time, tripped or not. Emits {CircuitBreakerReset}.
    ///
    /// Requirements:
    /// - The caller holds `OPERATOR_ROLE` (`AccessControlUnauthorizedAccount`).
    function resetBreaker() external;

    /// @notice Revokes a relayer key at once: the guardian's answer to a leaked opener or settler key. Granting a key
    ///         back needs the admin, the timelock on mainnet.
    /// @dev Emits OpenZeppelin's {RoleRevoked} if `account` held the role, and does nothing otherwise.
    ///
    /// Requirements (in check order):
    /// - The caller holds `GUARDIAN_ROLE` (`AccessControlUnauthorizedAccount`).
    /// - `role` is `OPENER_ROLE` or `SETTLER_ROLE` (`InvalidRelayerRole`).
    ///
    /// @param role The relayer role to revoke.
    /// @param account The key to revoke it from.
    function revokeRelayer(bytes32 role, address account) external;
}
