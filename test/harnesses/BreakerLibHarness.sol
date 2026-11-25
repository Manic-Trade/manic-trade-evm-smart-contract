// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {BreakerLib} from "../../src/libraries/BreakerLib.sol";
import {Breaker} from "../../src/types/StorageTypes.sol";

/// @title BreakerLibHarness
/// @notice Holds one `Breaker` in storage and exposes `BreakerLib`'s internal functions on it as external calls, so the
///         unit tests can drive it without a proxy.
contract BreakerLibHarness {
    using BreakerLib for Breaker;

    Breaker internal breaker;

    function set(Breaker calldata b) external {
        breaker = b;
    }

    function get() external view returns (Breaker memory) {
        return breaker;
    }

    function count(uint64 profit, uint64 loss, uint48 currentTime) external returns (bool) {
        return breaker.count(profit, loss, currentTime);
    }

    function reset(uint48 currentTime) external {
        breaker.reset(currentTime);
    }
}
