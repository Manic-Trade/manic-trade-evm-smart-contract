// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {LeverageMathHarness} from "../harnesses/LeverageMathHarness.sol";

/// @title LeverageMath_Unit_Shared_Test
/// @notice The shared set-up of the LeverageMath unit tests: a harness that exposes the library's internal
///         functions as external calls. Part 1 tests are in LeverageMath.t.sol; part 2 in LeverageMathChecks.t.sol
///         and LeverageMathSplits.t.sol; the leverage as an input in LeverageMathLeverage.t.sol.
abstract contract LeverageMath_Unit_Shared_Test is Test {
    LeverageMathHarness internal math;

    function setUp() public virtual {
        math = new LeverageMathHarness();
    }

    /// @dev The leverages the leverage tests sweep: both ends of the allowed range (1x, 10,000x), the three tiers
    ///      (100x, 500x, 1000x), two in between (15x, 2000x), and 4x, the lowest at which every cap up to 4x is
    ///      reachable.
    function _leverages() internal pure returns (uint16[8] memory) {
        return [uint16(1), 4, 15, 100, 500, 1000, 2000, 10_000];
    }
}
