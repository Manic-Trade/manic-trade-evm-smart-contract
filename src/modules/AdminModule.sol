// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {FlashOptionBase} from "../base/FlashOptionBase.sol";
import {IManicFlashOptionAdmin} from "../interfaces/IManicFlashOptionAdmin.sol";
import {BreakerLib} from "../libraries/BreakerLib.sol";
import {ConfigLib} from "../libraries/ConfigLib.sol";
import {ConfigParams} from "../types/ParamTypes.sol";
import {Breaker, Market} from "../types/StorageTypes.sol";

/// @title AdminModule
/// @author Manic
/// @notice The admin functions: creating markets and changing their settings, the two brakes (pause a market, halt
///         everything), the pool floor, the recipients, the safety refund's delay, the payout circuit breaker's
///         controls, and the guardian's revoke of a relayer key (docs/ARCHITECTURE.md §8.1, §8.9b, §8.11).
/// @dev Who may do what (§4.2):
///      - the admin (the 48-hour timelock on mainnet) creates markets, and sets the floor, the recipients, the
///        refund delay and the circuit breaker's limit and window;
///      - the operator (the admin Safe, instant) changes market settings, releases the brakes and resets the
///        circuit breaker;
///      - the guardian or the operator engages the brakes;
///      - the guardian revokes relayer keys.
///      None of these functions makes an external call. Each is `nonReentrant` all the same, like every
///      state-changing function, and the guard costs little with transient storage.
/// @custom:security-contact See SECURITY.md
abstract contract AdminModule is IManicFlashOptionAdmin, FlashOptionBase {
    using BreakerLib for Breaker;

    /// @notice The accepted range of a market's price exponent: prices scaled by 10^-18 at most, integers at least.
    int8 private constant _MIN_PRICE_EXPONENT = -18;
    int8 private constant _MAX_PRICE_EXPONENT = 0;

    /// @inheritdoc IManicFlashOptionAdmin
    function createMarket(
        bytes32 marketId,
        uint16 leverage,
        int8 priceExponent,
        ConfigParams calldata p
    )
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        Layout storage $ = _getFlashOptionStorage();
        if (marketId == bytes32(0)) revert InvalidLeverageParams();
        bytes32 key = _marketKey(marketId, leverage);
        if ($.marketIndexPlusOne[key] != 0) revert MarketExists();
        if (priceExponent < _MIN_PRICE_EXPONENT || priceExponent > _MAX_PRICE_EXPONENT) revert InvalidLeverageParams();
        if (p.enabled) revert InvalidLeverageParams(); // a market is always created switched off
        _validate(p, leverage); // the leverage itself first: 1x to 10,000x
        uint16 index = $.marketCount;
        // `marketIndexPlusOne` stores index + 1 in a uint16, so the last usable index is 65,534.
        if (index == type(uint16).max) revert MathOverflow();

        Market storage m = $.markets[index];
        m.marketId = marketId;
        m.leverage = leverage;
        m.priceExponent = priceExponent;
        _storeConfig(m, p); // `paused` starts false
        $.marketIndexPlusOne[key] = index + 1;
        $.marketCount = index + 1;

        emit MarketCreated(marketId, leverage, index, priceExponent);
        emit ConfigUpdated(marketId, leverage, _msgSender(), p);
    }

    /// @inheritdoc IManicFlashOptionAdmin
    function setConfig(
        bytes32 marketId,
        uint16 leverage,
        ConfigParams calldata p
    )
        external
        override
        nonReentrant
        onlyRole(OPERATOR_ROLE)
    {
        (Market storage m,) = _market(marketId, leverage);
        _validate(p, leverage); // the market's own leverage, which never changes
        _storeConfig(m, p);
        emit ConfigUpdated(marketId, leverage, _msgSender(), p);
    }

    /// @inheritdoc IManicFlashOptionAdmin
    function setPaused(bytes32 marketId, uint16 leverage, bool paused) external override nonReentrant {
        if (paused) _checkBrakeEngager();
        else if (!hasRole(OPERATOR_ROLE, _msgSender())) revert OnlyOperatorCanUnpause();
        (Market storage m,) = _market(marketId, leverage);
        m.paused = paused;
        emit PauseChanged(marketId, leverage, _msgSender(), paused);
    }

    /// @inheritdoc IManicFlashOptionAdmin
    function setHalted(bool halted) external override nonReentrant {
        if (halted) _checkBrakeEngager();
        else if (!hasRole(OPERATOR_ROLE, _msgSender())) revert OnlyOperatorCanUnhalt();
        _getFlashOptionStorage().halted = halted;
        emit HaltChanged(_msgSender(), halted);
    }

    /// @inheritdoc IManicFlashOptionAdmin
    function setPoolFloor(uint64 poolFloor) external override nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPoolFloor(poolFloor);
    }

    /// @inheritdoc IManicFlashOptionAdmin
    function setRecipients(
        address feeRecipient,
        address rewardsRecipient
    )
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setRecipients(feeRecipient, rewardsRecipient);
    }

    /// @inheritdoc IManicFlashOptionAdmin
    function setRefundDelay(uint48 refundDelaySecs) external override nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRefundDelay(refundDelaySecs);
    }

    /// @inheritdoc IManicFlashOptionAdmin
    function setBreaker(
        uint64 maxNetProfit,
        uint32 windowSecs
    )
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setBreaker(maxNetProfit, windowSecs);
    }

    /// @inheritdoc IManicFlashOptionAdmin
    function resetBreaker() external override nonReentrant onlyRole(OPERATOR_ROLE) {
        _getFlashOptionStorage().breaker.reset(_now48());
        emit CircuitBreakerReset(_msgSender());
    }

    /// @inheritdoc IManicFlashOptionAdmin
    function revokeRelayer(bytes32 role, address account) external override nonReentrant onlyRole(GUARDIAN_ROLE) {
        if (role != OPENER_ROLE && role != SETTLER_ROLE) revert InvalidRelayerRole(role);
        _revokeRole(role, account);
    }

    /// @notice Writes every setting of `p` into a market.
    /// @dev The market's id, pause and price exponent are not settings and are left alone.
    /// @param m The market's storage.
    /// @param p The settings, already validated.
    function _storeConfig(Market storage m, ConfigParams calldata p) private {
        m.enabled = p.enabled;
        m.entryMaxAgeSecs = p.entryMaxAgeSecs;
        m.clockSkewSecs = p.clockSkewSecs;
        m.floorMinBps = p.floorMinBps;
        m.floorMaxBps = p.floorMaxBps;
        m.capMinBps = p.capMinBps;
        m.capMaxBps = p.capMaxBps;
        m.maxSellFeeBps = p.maxSellFeeBps;
        m.sellMinDelaySecs = p.sellMinDelaySecs;
        m.sellCutoffSecs = p.sellCutoffSecs;
        m.maxExposureBps = p.maxExposureBps;
        m.minStake = p.minStake;
        m.maxStake = p.maxStake;
        m.maxTotalOwed = p.maxTotalOwed;
        // One rule at a time: the legacy pipeline can't copy a calldata array of structs to storage in one go.
        for (uint256 i; i < p.durations.length; ++i) {
            m.durations[i] = p.durations[i];
        }
    }

    /// @notice Engaging a brake (a pause or the halt) needs the guardian or the operator.
    /// @dev Reverts OpenZeppelin's `AccessControlUnauthorizedAccount`, naming `GUARDIAN_ROLE`: the role made for
    ///      braking. The operator may brake too, because the role that releases a brake can always re-engage it.
    function _checkBrakeEngager() private view {
        address caller = _msgSender();
        if (!hasRole(GUARDIAN_ROLE, caller) && !hasRole(OPERATOR_ROLE, caller)) {
            revert AccessControlUnauthorizedAccount(caller, GUARDIAN_ROLE);
        }
    }

    /// @notice Checks a market's settings with `ConfigLib.validate`, at the market's leverage.
    /// @dev A private function, so the library's checks are compiled once for both `createMarket` and `setConfig`.
    ///      An internal library function is inlined at every call site, and this one is about 1 KB.
    /// @param p The settings to check.
    /// @param leverage The market's leverage, which sets the limits on its lines and caps.
    function _validate(ConfigParams calldata p, uint16 leverage) private pure {
        ConfigLib.validate(p, leverage);
    }
}
