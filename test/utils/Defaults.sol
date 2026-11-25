// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {Examples} from "./Examples.sol";

/// @title Defaults
/// @notice The settings every test starts from, so no test carries a magic number (docs/CONVENTIONS.md §9). They are
///         the mainnet values where those are known.
library Defaults {
    /// @dev USDG's decimals: $1 is 1_000_000 base units.
    uint8 internal constant DECIMALS = 6;

    /// @dev The two-step admin transfer's delay on mainnet.
    uint48 internal constant ADMIN_TRANSFER_DELAY = 2 days;

    /// @dev The lowest floor allowed at 6 decimals: 500 whole tokens. Using the minimum proves the boundary passes.
    uint64 internal constant POOL_FLOOR = 500e6;

    /// @dev The most seed recovery may return in total: 500 whole tokens (`LeverageMath.SEED_RECOVERY_CAP_TOKENS`) at
    ///      6 decimals.
    uint64 internal constant SEED_RECOVERY_CAP = 500e6;

    /// @dev The safety refund delay after a position's expiry.
    uint48 internal constant REFUND_DELAY = 24 hours;

    /// @dev The circuit breaker: $1,000 of net profit allowed out per 1-hour window.
    uint64 internal constant BREAKER_MAX_NET_PROFIT = 1000e6;
    uint32 internal constant BREAKER_WINDOW = 1 hours;

    /// @dev What the contract says about itself.
    string internal constant VERSION = "1.0.0";
    string internal constant EIP712_NAME = "Manic Flash Option";
    string internal constant EIP712_VERSION = "1";

    /// @dev The markets: Pyth's BTC/USD and ETH/USD feed ids, and their price exponent.
    bytes32 internal constant BTC = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 internal constant ETH = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    int8 internal constant PRICE_EXPONENT = -8;
    /// @dev The test market's leverage: BTC at 1000x, its launch leverage. One feed can have a market per leverage
    ///      (ADR 0008); the tests that need others create them.
    uint16 internal constant LEVERAGE = 1000;

    /// @dev The base terms of a bet: a $10 one-minute bet at θ 3.00 bp, floor 1.3x, cap 4x, at the example BTC price
    ///      ($83,884, `Examples.P0`).
    uint64 internal constant STAKE = 10e6;
    uint16 internal constant DURATION = 60;
    uint32 internal constant THETA = 3000;
    uint16 internal constant FLOOR_BPS = 13_000;
    uint16 internal constant CAP_BPS = 40_000;
    int64 internal constant ENTRY_PRICE = Examples.P0;

    /// @dev How long a signed order stays valid: the backend's ~30 s (ARCHITECTURE §7).
    uint48 internal constant ORDER_LIFETIME = 30;

    /// @dev How long a stake authorisation stays valid, from one second before it is signed.
    uint256 internal constant AUTH_LIFETIME = 60;

    /// @dev The launch settings: `Examples.launchConfig` with the exposure gate at 100% (ARCHITECTURE §6.3, ADR 0009),
    ///      switched off as `createMarket` requires. `Base_Test` switches BTC on with `setConfig`.
    function marketConfig() internal pure returns (ConfigParams memory c) {
        c = Examples.launchConfig();
        c.maxExposureBps = 10_000;
    }
}
