// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

import {IManicFlashOptionErrors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {ConfigLibHarness} from "../harnesses/ConfigLibHarness.sol";
import {Calculations} from "../utils/Calculations.sol";
import {LeverageConfigs} from "../utils/LeverageConfigs.sol";

/// @title ConfigLib_Fuzz_Test
/// @notice `ConfigLib.validate` accepts exactly the settings its definition accepts, at any leverage. The worked
///         examples are in test/unit/ConfigLib.t.sol.
/// @dev Each case picks a leverage: one of ten in range (1x, 2x, 3x and 4x, where the reachable cap binds or stops
///      binding; 15x; the planned 100x, 500x and 1000x; 2000x; 10,000x) or one of two just outside it. It starts from
///      the launch config fitted to that leverage (`LeverageConfigs.launchAt`) and makes up to three random changes.
///      Each change sets one field, or one duration rule, to a value at or next to one of its limits, including the
///      two the leverage sets: the widest line and the highest reachable cap. So valid and invalid settings both come
///      up often. Fully random settings are almost never valid, which would leave the "accepts" side untested. The
///      reference is `Calculations.isValidConfig`, which never calls `src/`. CI runs 10,000 cases.
contract ConfigLib_Fuzz_Test is Test {
    ConfigLibHarness internal lib;

    function setUp() public {
        lib = new ConfigLibHarness();
    }

    function testFuzz_ValidateMatchesItsDefinition(uint256 seed) public view {
        uint16 leverage = leverageFor(seed);
        ConfigParams memory c = mutatedLaunchConfig(seed, leverage);
        bool expected = Calculations.isValidConfig(c, leverage);
        try lib.validate(c, leverage) {
            assertTrue(expected, "accepted settings its definition rejects");
        } catch (bytes memory reason) {
            assertFalse(expected, "rejected settings its definition accepts");
            assertEq(bytes4(reason), IManicFlashOptionErrors.InvalidLeverageParams.selector);
        }
    }

    /// @dev The leverage of the case, picked by `seed`: ten in range and two just outside it (0x and 10,001x).
    function leverageFor(uint256 seed) internal pure returns (uint16) {
        uint16[12] memory picks = [uint16(1), 2, 3, 4, 15, 100, 500, 1000, 2000, 10_000, 0, 10_001];
        return picks[uint256(keccak256(abi.encode(seed, "leverage"))) % picks.length];
    }

    /// @dev The launch config fitted to `leverage` (`LeverageConfigs.launchAt`, so it starts valid) with up to three
    ///      boundary changes, chosen by `seed`.
    function mutatedLaunchConfig(uint256 seed, uint16 leverage) internal pure returns (ConfigParams memory c) {
        c = LeverageConfigs.launchAt(leverage);
        for (uint256 k; k < 3; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            if (r % 3 == 0) continue; // a third of the changes are skipped
            mutate(c, r >> 8, leverage);
        }
    }

    /// @dev Sets one field, picked by `r`, to a value at or next to one of its limits: some valid, some not. The
    ///      highest cap and the widest line also try the limits `leverage` sets.
    function mutate(ConfigParams memory c, uint256 r, uint16 leverage) internal pure {
        // Wrapping is fine: a wrapped value is just one more value to test.
        unchecked {
            uint256 pick = (r >> 8) % 4;
            uint256 field = r % 11;
            if (field == 0) {
                c.minStake = [0, 1, c.maxStake, c.maxStake + 1][pick];
            } else if (field == 1) {
                c.maxStake = [c.minStake - 1, c.minStake, c.minStake + 1, type(uint64).max][pick];
            } else if (field == 2) {
                c.floorMinBps = uint16([10_000, 10_001, uint256(c.floorMaxBps), c.floorMaxBps + 1][pick]);
            } else if (field == 3) {
                c.floorMaxBps = uint16([uint256(c.floorMinBps) - 1, c.floorMinBps, c.capMaxBps, c.capMaxBps + 1][pick]);
            } else if (field == 4) {
                c.capMinBps = uint16([10_000, 10_001, uint256(c.capMaxBps), c.capMaxBps + 1][pick]);
            } else if (field == 5) {
                // The highest cap a short can reach at this leverage, capped at one past the 4x ceiling.
                uint256 top = Math.min((uint256(leverage) + 1) * 10_000 - 1, 40_001);
                uint256 choice = (r >> 8) % 6;
                c.capMaxBps = uint16([uint256(c.floorMaxBps) - 1, c.floorMaxBps, 40_000, 40_001, top, top + 1][choice]);
            } else if (field == 6) {
                c.maxSellFeeBps = uint16([0, 9999, 10_000, 10_001][pick]);
            } else if (field == 7) {
                c.entryMaxAgeSecs = uint8([0, 1, 5, 255][pick]);
            } else if (field == 8) {
                c.maxExposureBps = uint32([0, 1, 10_000, 10_001][pick]);
            } else if (field == 9) {
                c.clockSkewSecs = uint8([0, 30, 31, 255][pick]);
            } else {
                mutateRule(c, r >> 16, leverage);
            }
        }
    }

    /// @dev Changes one duration rule: its duration (to 0, to another rule's duration, or to a new one), its θ range
    ///      at the edges (the widest line at `leverage` and one past it among them), its switch, or clears it (fully or
    ///      leaving a θ behind).
    function mutateRule(ConfigParams memory c, uint256 r, uint16 leverage) internal pure {
        unchecked {
            uint256 i = r % 5;
            uint256 change = (r >> 8) % 7;
            if (change == 0) {
                c.durations[i].durationSecs = 0;
            } else if (change == 1) {
                c.durations[i].durationSecs = c.durations[(i + 1) % 5].durationSecs;
            } else if (change == 2) {
                c.durations[i].durationSecs = 900;
            } else if (change == 3) {
                c.durations[i].thetaMinE7 =
                    uint32([0, 1, c.durations[i].thetaMaxE7, c.durations[i].thetaMaxE7 + 1][(r >> 16) % 4]);
            } else if (change == 4) {
                // The widest line at this leverage: the largest θ with θ × L < 1e7 (1000x's 9,999 when out of
                // range).
                uint256 widest = leverage == 0 || leverage > 10_000 ? 9999 : (1e7 - 1) / leverage;
                c.durations[i].thetaMaxE7 =
                    uint32([uint256(c.durations[i].thetaMinE7), widest, widest + 1, 30_000][(r >> 16) % 4]);
            } else if (change == 5) {
                c.durations[i].enabled = !c.durations[i].enabled;
            } else {
                (
                    c.durations[i].durationSecs,
                    c.durations[i].thetaMinE7,
                    c.durations[i].thetaMaxE7,
                    c.durations[i].enabled
                ) = (0, 0, (r >> 16) % 2 == 0 ? 0 : 1, false);
            }
        }
    }
}
