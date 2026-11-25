// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DurationRule} from "./StorageTypes.sol";

// The parameter structs of the admin functions. They are never stored as they are, so unlike StorageTypes.sol they
// may still change before mainnet. They are part of the ABI, though (`ConfigUpdated` carries a `ConfigParams`), so
// changing one is an ABI change (docs/CONVENTIONS.md §6).

/// @notice A market's settings, as `createMarket` and `setConfig` take them (docs/ARCHITECTURE.md §6.3, §8.1).
/// @dev The same fields, in the same order, as `Market` without `marketId`, `priceExponent` and `leverage` (all
///      fixed at creation) and `paused` (its own switch). `setConfig` replaces them all at once, and
///      `ConfigLib.validate` checks them first.
struct ConfigParams {
    bool enabled; // whether new bets may open and sell
    uint8 entryMaxAgeSecs; // how old the price tick of an open or a sale may be
    uint8 clockSkewSecs; // how far ahead of the chain's clock a tick's time may be; at most 30 (ADR 0009)
    uint16 floorMinBps; // the range of floors, the least a right call pays
    uint16 floorMaxBps;
    uint16 capMinBps; // the range of caps, the most a bet pays (at most 40_000 = 4x)
    uint16 capMaxBps;
    uint16 maxSellFeeBps; // the largest early-sell fee, as a share of the valuation
    uint16 sellMinDelaySecs; // a sale is allowed from start + this...
    uint16 sellCutoffSecs; // ...until more than this before the end
    uint32 maxExposureBps; // open gate: open max profit ≤ free money × this / 10_000; 1 to 10_000 (ADR 0009)
    uint64 minStake; // the smallest stake, in base units
    uint64 maxStake; // the largest stake, in base units
    uint64 maxTotalOwed; // open gate: new bets are blocked while total owed exceeds this
    DurationRule[5] durations; // the allowed durations; unused rules are all zero
}

/// @notice Everything `initialize` sets, in one struct (docs/ARCHITECTURE.md §6.7, §8.1).
/// @dev The role holders differ by network (§4.2). On mainnet the admin and the upgrader are the 48-hour
///      `TimelockController`, and the operator is the admin Safe. On the testnet they may be the deployer.
struct InitParams {
    address admin; // DEFAULT_ADMIN_ROLE: the timelock on mainnet
    uint48 adminTransferDelay; // the delay of the two-step admin transfer (mainnet: 2 days)
    address upgrader; // UPGRADER_ROLE: the timelock on mainnet
    address operator; // OPERATOR_ROLE: the admin Safe on mainnet
    address guardian; // GUARDIAN_ROLE: halts, pauses and revokes relayer keys
    address[] openers; // OPENER_ROLE: the backend accounts that open and sell
    address[] settlers; // SETTLER_ROLE: the backend accounts that liquidate and settle
    IERC20 token; // the stablecoin (USDG), with 6 to 9 decimals
    uint64 poolFloor; // at least 500 whole tokens
    address feeRecipient; // receives swept fees and seed recovery
    address rewardsRecipient; // receives rewards withdrawals
    uint48 refundDelaySecs; // the safety refund delay after expiry (24 hours; 0 = off)
    uint64 breakerMaxNetProfit; // the circuit breaker's limit per window (0 = off)
    uint32 breakerWindowSecs; // the circuit breaker's window (for example 3_600)
}
