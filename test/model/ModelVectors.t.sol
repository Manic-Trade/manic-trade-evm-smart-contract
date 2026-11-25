// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {stdError} from "forge-std/StdError.sol";
import {Test} from "forge-std/Test.sol";

import {IManicFlashOptionErrors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {RepaySplit, SellSplit, SettleSplit} from "../../src/types/MathTypes.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {Side, WithdrawPurpose} from "../../src/types/StorageTypes.sol";
import {ConfigLibHarness} from "../harnesses/ConfigLibHarness.sol";
import {LeverageMathHarness} from "../harnesses/LeverageMathHarness.sol";

// The contract's maths against a second implementation of docs/MATH.md: the reference model,
// model/flash_option_math.py, written in Python from the document. model/generate_vectors.py runs the model on about
// 20,000 inputs (the edges of every rule, the worked examples of docs/MATH.md §12, and seeded random inputs over each
// function's whole domain, at each leverage tier and at any leverage) and writes what it gives to
// test/fixtures/model/<function>.json. These tests feed every input to the contract's code through the harnesses and
// require the same outputs, or the same error. A mistake in the maths would have to be made twice, the same way, in
// two languages, to pass. model/README.md says how to regenerate the vectors.

/// @title ModelVectors_Shared_Test
/// @notice Reads a function's vectors and turns the error names the model gives into the contract's revert data.
/// @dev Each file has `cases` (inputs and the outputs the model gives, or none for a check that passes) and `reverts`
///      (inputs and `errorName`), and counts both in its header. A file is read with `vm.parseJsonTypeArray` and an
///      explicit type string (docs/CONVENTIONS.md §9). The inputs and the outputs of a case are decoded as two
///      structs, each type naming only its own keys, so one inputs struct serves both lists.
abstract contract ModelVectors_Shared_Test is Test {
    /// @dev The error a refused input gets, as the model names it.
    struct Named {
        string errorName;
    }

    /// @dev Reads test/fixtures/model/`name`.json and checks it holds `name`'s vectors.
    function _vectors(string memory name) internal view returns (string memory json) {
        json = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/model/", name, ".json"));
        assertEq(vm.parseJsonString(json, ".function"), name, "the file holds the function's vectors");
    }

    /// @dev The cases the model accepts, ABI-encoded as an array of `typeDescription`.
    function _cases(string memory json, string memory typeDescription) internal pure returns (bytes memory) {
        return vm.parseJsonTypeArray(json, ".cases", typeDescription);
    }

    /// @dev The cases the model refuses, ABI-encoded as an array of `typeDescription`.
    function _reverts(string memory json, string memory typeDescription) internal pure returns (bytes memory) {
        return vm.parseJsonTypeArray(json, ".reverts", typeDescription);
    }

    /// @dev Checks that the file's header (`key`: ".caseCount" or ".revertCount") counts `count` entries, so a file
    ///      cut short fails.
    function _assertCount(string memory json, string memory key, uint256 count) internal pure {
        assertEq(count, vm.parseJsonUint(json, key), string.concat("the header's ", key));
    }

    /// @dev The error names of the refused cases, in order.
    function _errorNames(string memory json) internal pure returns (string[] memory names) {
        Named[] memory named = abi.decode(_reverts(json, "Named(string errorName)"), (Named[]));
        _assertCount(json, ".revertCount", named.length);
        names = new string[](named.length);
        for (uint256 i; i < named.length; ++i) {
            names[i] = named[i].errorName;
        }
    }

    /// @dev The revert data of the error the model names: one of the contract's custom errors, or Solidity's
    ///      arithmetic panic (0x11) or division panic (0x12). A name the table doesn't know fails the test.
    function _revertData(string memory name) internal pure returns (bytes memory) {
        bytes32 nameHash = keccak256(bytes(name));
        if (nameHash == keccak256("Panic(0x11)")) return stdError.arithmeticError;
        if (nameHash == keccak256("Panic(0x12)")) return stdError.divisionError;
        string[19] memory names = [
            "InvalidPrice",
            "InvalidLeverageParams",
            "MathOverflow",
            "InvalidAmount",
            "PriceTooOld",
            "PriceFromFuture",
            "OpenBlockedTotalOwed",
            "OpenBlockedExposure",
            "SellWindowClosed",
            "ValuationAboveCurrentPayout",
            "SellAmountExceedsValuation",
            "SellFeeTooHigh",
            "SellAmountBelowMin",
            "QueueNotEmpty",
            "SellNotPayable",
            "OwedOutstanding",
            "BelowPoolFloor",
            "OpenExposureNotCovered",
            "SeedRecoveryExceeded"
        ];
        bytes4[19] memory selectors = [
            IManicFlashOptionErrors.InvalidPrice.selector,
            IManicFlashOptionErrors.InvalidLeverageParams.selector,
            IManicFlashOptionErrors.MathOverflow.selector,
            IManicFlashOptionErrors.InvalidAmount.selector,
            IManicFlashOptionErrors.PriceTooOld.selector,
            IManicFlashOptionErrors.PriceFromFuture.selector,
            IManicFlashOptionErrors.OpenBlockedTotalOwed.selector,
            IManicFlashOptionErrors.OpenBlockedExposure.selector,
            IManicFlashOptionErrors.SellWindowClosed.selector,
            IManicFlashOptionErrors.ValuationAboveCurrentPayout.selector,
            IManicFlashOptionErrors.SellAmountExceedsValuation.selector,
            IManicFlashOptionErrors.SellFeeTooHigh.selector,
            IManicFlashOptionErrors.SellAmountBelowMin.selector,
            IManicFlashOptionErrors.QueueNotEmpty.selector,
            IManicFlashOptionErrors.SellNotPayable.selector,
            IManicFlashOptionErrors.OwedOutstanding.selector,
            IManicFlashOptionErrors.BelowPoolFloor.selector,
            IManicFlashOptionErrors.OpenExposureNotCovered.selector,
            IManicFlashOptionErrors.SeedRecoveryExceeded.selector
        ];
        for (uint256 i; i < names.length; ++i) {
            if (keccak256(bytes(names[i])) == nameHash) return abi.encodeWithSelector(selectors[i]);
        }
        assertTrue(false, string.concat("an error name the test does not know: ", name));
        return "";
    }

    /// @dev The label of entry `i` of `list` in `name`'s vectors, for assertion messages.
    function _at(string memory name, string memory list, uint256 i) internal pure returns (string memory) {
        return string.concat(name, ".", list, "[", vm.toString(i), "]");
    }
}

/// @title LeverageMath_ModelVectors_Test
/// @notice Every function of `LeverageMath` against the reference model's vectors: the same outputs for every case,
///         and the same error, with its arguments, for every refused input.
/// @dev Many refused inputs break several rules at once, so getting the model's error also proves the contract checks
///      them in the order docs/MATH.md gives. A function the model never refuses has no `reverts`, and its test checks
///      that the count is 0.
contract LeverageMath_ModelVectors_Test is ModelVectors_Shared_Test {
    struct FloorDivIn {
        int256 a;
        int256 b;
    }

    struct FloorDivOut {
        int256 q;
    }

    struct LeverageAllowedCase {
        uint16 leverage;
        bool allowed;
    }

    struct ThetaWithinLimitCase {
        uint32 thetaE7;
        uint16 leverage;
        bool within;
    }

    struct CapReachableCase {
        uint16 capBps;
        uint16 leverage;
        bool reachable;
    }

    struct LinesIn {
        int64 entry;
        uint8 side;
        uint16 leverage;
        uint32 thetaE7;
        uint16 capBps;
    }

    struct LinesOut {
        int64 liqPrice;
        int64 capPrice;
    }

    struct CapLineIn {
        int64 entry;
        uint8 side;
        uint16 leverage;
        uint16 capBps;
    }

    struct CapPriceOut {
        int64 capPrice;
    }

    struct GBpsIn {
        int64 entry;
        int64 price;
        uint8 side;
        uint16 leverage;
        uint16 floorBps;
        uint16 capBps;
    }

    struct GBpsOut {
        uint16 g;
    }

    struct PayoutIn {
        uint64 stake;
        uint16 multipleBps;
    }

    struct MaxProfitIn {
        uint64 stake;
        uint16 capBps;
    }

    struct AmountOut {
        uint64 amount;
    }

    struct TouchedCase {
        int64 price;
        int64 liqPrice;
        uint8 side;
        bool touched;
    }

    struct CheckLiquidationIn {
        uint256 positionId;
        uint256 startTime;
        uint256 endTime;
        int64 liqPrice;
        uint8 side;
        int64 price;
        uint256 publishTime;
        uint256 currentTime;
        uint8 clockSkewSecs;
    }

    struct CheckEntryTimeIn {
        uint256 currentTime;
        uint256 publishTime;
        uint8 maxAgeSecs;
        uint8 clockSkewSecs;
    }

    struct OpenGateIn {
        uint64 totalOwed;
        uint64 maxTotalOwed;
        uint64 openMaxProfit;
        uint64 newMaxProfit;
        uint64 free;
        uint32 maxExposureBps;
    }

    struct FeeCase {
        uint64 amount;
        uint16 feeBps;
        uint64 fee;
    }

    struct WinnerFeeCase {
        uint64 profitPaid;
        uint64 fee;
    }

    struct LoserFeeCase {
        uint64 loss;
        uint64 freeBefore;
        uint64 poolFloor;
        uint64 fee;
    }

    struct SettleSplitIn {
        uint64 payoutAmount;
        uint64 stake;
        uint64 freeBefore;
        uint64 totalOwed;
        uint64 poolFloor;
    }

    struct SettleSplitOut {
        uint64 own;
        uint64 paid;
        uint64 owed;
        uint64 winnerFee;
        uint64 loserFee;
        uint64 toUser;
        uint64 outOfPool;
    }

    struct CheckSellWindowIn {
        uint256 startTime;
        uint256 endTime;
        uint256 publishTime;
        uint16 minDelaySecs;
        uint16 cutoffSecs;
    }

    struct CheckSellIn {
        uint64 stake;
        uint16 gNowBps;
        uint64 valuation;
        uint64 sellAmount;
        uint64 minAmount;
        uint16 maxSellFeeBps;
        uint64 totalOwed;
        uint64 freeBefore;
    }

    struct SellSplitIn {
        uint64 stake;
        uint64 valuation;
        uint64 sellAmount;
        uint64 freeBefore;
        uint64 poolFloor;
    }

    struct SellSplitOut {
        uint64 toUser;
        uint64 sellFee;
        uint64 winnerFee;
        uint64 loserFee;
        uint64 fees;
        uint64 outOfPool;
    }

    struct RepaySplitCase {
        uint64 owed;
        uint64 free;
        uint64 amount;
        uint64 winnerFee;
        uint64 toUser;
        uint64 remaining;
    }

    struct CheckWithdrawIn {
        uint8 purpose;
        uint64 amount;
        uint64 free;
        uint64 totalOwed;
        uint64 poolFloor;
        uint64 openMaxProfit;
        uint64 seedRecovered;
        uint8 decimals;
    }

    string internal constant LINES_IN = "LinesIn(int64 entry,uint8 side,uint16 leverage,uint32 thetaE7,uint16 capBps)";
    string internal constant CAP_LINE_IN = "CapLineIn(int64 entry,uint8 side,uint16 leverage,uint16 capBps)";
    string internal constant G_BPS_IN =
        "GBpsIn(int64 entry,int64 price,uint8 side,uint16 leverage,uint16 floorBps,uint16 capBps)";
    string internal constant CHECK_LIQUIDATION_IN = "CheckLiquidationIn(uint256 positionId,uint256 startTime,"
        "uint256 endTime,int64 liqPrice,uint8 side,int64 price,uint256 publishTime,uint256 currentTime,"
        "uint8 clockSkewSecs)";
    string internal constant CHECK_ENTRY_TIME_IN =
        "CheckEntryTimeIn(uint256 currentTime,uint256 publishTime,uint8 maxAgeSecs,uint8 clockSkewSecs)";
    string internal constant OPEN_GATE_IN = "OpenGateIn(uint64 totalOwed,uint64 maxTotalOwed,uint64 openMaxProfit,"
        "uint64 newMaxProfit,uint64 free,uint32 maxExposureBps)";
    string internal constant SETTLE_SPLIT_IN =
        "SettleSplitIn(uint64 payoutAmount,uint64 stake,uint64 freeBefore,uint64 totalOwed,uint64 poolFloor)";
    string internal constant SETTLE_SPLIT_OUT = "SettleSplitOut(uint64 own,uint64 paid,uint64 owed,uint64 winnerFee,"
        "uint64 loserFee,uint64 toUser,uint64 outOfPool)";
    string internal constant CHECK_SELL_WINDOW_IN = "CheckSellWindowIn(uint256 startTime,uint256 endTime,"
        "uint256 publishTime,uint16 minDelaySecs,uint16 cutoffSecs)";
    string internal constant CHECK_SELL_IN = "CheckSellIn(uint64 stake,uint16 gNowBps,uint64 valuation,"
        "uint64 sellAmount,uint64 minAmount,uint16 maxSellFeeBps,uint64 totalOwed,uint64 freeBefore)";
    string internal constant SELL_SPLIT_IN =
        "SellSplitIn(uint64 stake,uint64 valuation,uint64 sellAmount,uint64 freeBefore,uint64 poolFloor)";
    string internal constant SELL_SPLIT_OUT = "SellSplitOut(uint64 toUser,uint64 sellFee,uint64 winnerFee,"
        "uint64 loserFee,uint64 fees,uint64 outOfPool)";
    string internal constant CHECK_WITHDRAW_IN = "CheckWithdrawIn(uint8 purpose,uint64 amount,uint64 free,"
        "uint64 totalOwed,uint64 poolFloor,uint64 openMaxProfit,uint64 seedRecovered,uint8 decimals)";

    LeverageMathHarness internal math;

    function setUp() public {
        math = new LeverageMathHarness();
    }

    /// @dev `floorDiv` floors in every sign combination, at the int256 extremes and one unit either side of a
    ///      multiple, and panics on a zero divisor and on the one quotient that overflows (docs/MATH.md §11).
    function test_FloorDivMatchesTheModel() external {
        string memory json = _vectors("floorDiv");
        FloorDivIn[] memory ins = abi.decode(_cases(json, "FloorDivIn(int256 a,int256 b)"), (FloorDivIn[]));
        FloorDivOut[] memory outs = abi.decode(_cases(json, "FloorDivOut(int256 q)"), (FloorDivOut[]));
        _assertCount(json, ".caseCount", ins.length);
        for (uint256 i; i < ins.length; ++i) {
            assertEq(math.floorDiv(ins[i].a, ins[i].b), outs[i].q, _at("floorDiv", "cases", i));
        }
        ins = abi.decode(_reverts(json, "FloorDivIn(int256 a,int256 b)"), (FloorDivIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            vm.expectRevert(_revertData(errors[i]));
            math.floorDiv(ins[i].a, ins[i].b);
        }
    }

    /// @dev `leverageAllowed` takes exactly 1 to 10,000 (docs/MATH.md §3.1 rule 1).
    function test_LeverageAllowedMatchesTheModel() external view {
        string memory json = _vectors("leverageAllowed");
        LeverageAllowedCase[] memory cases =
            abi.decode(_cases(json, "LeverageAllowedCase(uint16 leverage,bool allowed)"), (LeverageAllowedCase[]));
        _assertCount(json, ".caseCount", cases.length);
        _assertCount(json, ".revertCount", 0);
        for (uint256 i; i < cases.length; ++i) {
            assertEq(math.leverageAllowed(cases[i].leverage), cases[i].allowed, _at("leverageAllowed", "cases", i));
        }
    }

    /// @dev `thetaWithinLimit`: thetaE7 × L < 10^7, at each leverage's widest line and one unit past it
    ///      (docs/MATH.md §3.1, Example 7).
    function test_ThetaWithinLimitMatchesTheModel() external view {
        string memory json = _vectors("thetaWithinLimit");
        ThetaWithinLimitCase[] memory cases = abi.decode(
            _cases(json, "ThetaWithinLimitCase(uint32 thetaE7,uint16 leverage,bool within)"), (ThetaWithinLimitCase[])
        );
        _assertCount(json, ".caseCount", cases.length);
        _assertCount(json, ".revertCount", 0);
        for (uint256 i; i < cases.length; ++i) {
            ThetaWithinLimitCase memory c = cases[i];
            assertEq(math.thetaWithinLimit(c.thetaE7, c.leverage), c.within, _at("thetaWithinLimit", "cases", i));
        }
    }

    /// @dev `capReachable`: cap − 1x < L, at each low leverage's highest cap and one bp past it, and for caps at or
    ///      below 1x (docs/MATH.md §3.1 rule 6).
    function test_CapReachableMatchesTheModel() external view {
        string memory json = _vectors("capReachable");
        CapReachableCase[] memory cases = abi.decode(
            _cases(json, "CapReachableCase(uint16 capBps,uint16 leverage,bool reachable)"), (CapReachableCase[])
        );
        _assertCount(json, ".caseCount", cases.length);
        _assertCount(json, ".revertCount", 0);
        for (uint256 i; i < cases.length; ++i) {
            CapReachableCase memory c = cases[i];
            assertEq(math.capReachable(c.capBps, c.leverage), c.reachable, _at("capReachable", "cases", i));
        }
    }

    /// @dev `lines` draws the same two lines for every bet: the worked examples of the three tiers, the widest line
    ///      and highest cap of each swept leverage, exact and inexact offsets, and the largest entry whose outer line
    ///      still fits int64; and refuses the rest with the same error, the price before the parameters before the
    ///      narrowing (docs/MATH.md §4).
    function test_LinesMatchTheModel() external {
        string memory json = _vectors("lines");
        LinesIn[] memory ins = abi.decode(_cases(json, LINES_IN), (LinesIn[]));
        LinesOut[] memory outs = abi.decode(_cases(json, "LinesOut(int64 liqPrice,int64 capPrice)"), (LinesOut[]));
        _assertCount(json, ".caseCount", ins.length);
        for (uint256 i; i < ins.length; ++i) {
            (int64 liqPrice, int64 capPrice) = _lines(ins[i]);
            assertEq(liqPrice, outs[i].liqPrice, string.concat(_at("lines", "cases", i), ".liqPrice"));
            assertEq(capPrice, outs[i].capPrice, string.concat(_at("lines", "cases", i), ".capPrice"));
        }
        ins = abi.decode(_reverts(json, LINES_IN), (LinesIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            vm.expectRevert(_revertData(errors[i]));
            _lines(ins[i]);
        }
    }

    /// @dev `capLine` gives the same cap line as the model, and refuses the same inputs with the same error
    ///      (docs/MATH.md §4).
    function test_CapLineMatchesTheModel() external {
        string memory json = _vectors("capLine");
        CapLineIn[] memory ins = abi.decode(_cases(json, CAP_LINE_IN), (CapLineIn[]));
        CapPriceOut[] memory outs = abi.decode(_cases(json, "CapPriceOut(int64 capPrice)"), (CapPriceOut[]));
        _assertCount(json, ".caseCount", ins.length);
        for (uint256 i; i < ins.length; ++i) {
            assertEq(_capLine(ins[i]), outs[i].capPrice, _at("capLine", "cases", i));
        }
        ins = abi.decode(_reverts(json, CAP_LINE_IN), (CapLineIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            vm.expectRevert(_revertData(errors[i]));
            _capLine(ins[i]);
        }
    }

    /// @dev `gBps` gives the same multiple along the whole curve: the floor on a win, the cap, 0, a move of R = 0,
    ///      the price where R steps and one unit before it, at the three tiers and at any leverage; and refuses the
    ///      same inputs, the prices before the leverage (docs/MATH.md §5).
    function test_GBpsMatchesTheModel() external {
        string memory json = _vectors("gBps");
        GBpsIn[] memory ins = abi.decode(_cases(json, G_BPS_IN), (GBpsIn[]));
        GBpsOut[] memory outs = abi.decode(_cases(json, "GBpsOut(uint16 g)"), (GBpsOut[]));
        _assertCount(json, ".caseCount", ins.length);
        for (uint256 i; i < ins.length; ++i) {
            assertEq(_gBps(ins[i]), outs[i].g, _at("gBps", "cases", i));
        }
        ins = abi.decode(_reverts(json, G_BPS_IN), (GBpsIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            vm.expectRevert(_revertData(errors[i]));
            _gBps(ins[i]);
        }
    }

    /// @dev `payout` rounds down like the model, and overflows uint64 at the same stake, one unit past the largest
    ///      that fits (docs/MATH.md §5).
    function test_PayoutMatchesTheModel() external {
        string memory json = _vectors("payout");
        string memory inType = "PayoutIn(uint64 stake,uint16 multipleBps)";
        PayoutIn[] memory ins = abi.decode(_cases(json, inType), (PayoutIn[]));
        AmountOut[] memory outs = abi.decode(_cases(json, "AmountOut(uint64 amount)"), (AmountOut[]));
        _assertCount(json, ".caseCount", ins.length);
        for (uint256 i; i < ins.length; ++i) {
            assertEq(math.payout(ins[i].stake, ins[i].multipleBps), outs[i].amount, _at("payout", "cases", i));
        }
        ins = abi.decode(_reverts(json, inType), (PayoutIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            vm.expectRevert(_revertData(errors[i]));
            math.payout(ins[i].stake, ins[i].multipleBps);
        }
    }

    /// @dev `maxProfit` matches the model, refuses a cap below 1x before it can overflow, and overflows at the same
    ///      stake (docs/MATH.md §5).
    function test_MaxProfitMatchesTheModel() external {
        string memory json = _vectors("maxProfit");
        string memory inType = "MaxProfitIn(uint64 stake,uint16 capBps)";
        MaxProfitIn[] memory ins = abi.decode(_cases(json, inType), (MaxProfitIn[]));
        AmountOut[] memory outs = abi.decode(_cases(json, "AmountOut(uint64 amount)"), (AmountOut[]));
        _assertCount(json, ".caseCount", ins.length);
        for (uint256 i; i < ins.length; ++i) {
            assertEq(math.maxProfit(ins[i].stake, ins[i].capBps), outs[i].amount, _at("maxProfit", "cases", i));
        }
        ins = abi.decode(_reverts(json, inType), (MaxProfitIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            vm.expectRevert(_revertData(errors[i]));
            math.maxProfit(ins[i].stake, ins[i].capBps);
        }
    }

    /// @dev `touched`: at or past the line, equality included, on both sides and across the int64 range
    ///      (docs/MATH.md §4).
    function test_TouchedMatchesTheModel() external view {
        string memory json = _vectors("touched");
        TouchedCase[] memory cases = abi.decode(
            _cases(json, "TouchedCase(int64 price,int64 liqPrice,uint8 side,bool touched)"), (TouchedCase[])
        );
        _assertCount(json, ".caseCount", cases.length);
        _assertCount(json, ".revertCount", 0);
        for (uint256 i; i < cases.length; ++i) {
            TouchedCase memory c = cases[i];
            assertEq(math.touched(c.price, c.liqPrice, Side(c.side)), c.touched, _at("touched", "cases", i));
        }
    }

    /// @dev `checkLiquidation` lets through every tick the model does, and refuses the rest with the same error and
    ///      position id: the price, then the bet's window (both ends included), then the skew, then the line
    ///      (docs/MATH.md §7.1).
    function test_CheckLiquidationMatchesTheModel() external {
        string memory json = _vectors("checkLiquidation");
        CheckLiquidationIn[] memory ins = abi.decode(_cases(json, CHECK_LIQUIDATION_IN), (CheckLiquidationIn[]));
        _assertCount(json, ".caseCount", ins.length);
        for (uint256 i; i < ins.length; ++i) {
            _checkLiquidation(ins[i]);
        }
        ins = abi.decode(_reverts(json, CHECK_LIQUIDATION_IN), (CheckLiquidationIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            bytes32 nameHash = keccak256(bytes(errors[i]));
            bytes32 positionId = bytes32(ins[i].positionId);
            // The two errors that depend on the position name it.
            if (nameHash == keccak256("InvalidLiquidationWindow")) {
                vm.expectRevert(
                    abi.encodeWithSelector(IManicFlashOptionErrors.InvalidLiquidationWindow.selector, positionId)
                );
            } else if (nameHash == keccak256("LiquidationPriceNotReached")) {
                vm.expectRevert(
                    abi.encodeWithSelector(IManicFlashOptionErrors.LiquidationPriceNotReached.selector, positionId)
                );
            } else {
                vm.expectRevert(_revertData(errors[i]));
            }
            _checkLiquidation(ins[i]);
        }
    }

    /// @dev `checkEntryTime` accepts exactly the ticks from `now − entryMaxAgeSecs` to `now + clockSkewSecs`, and
    ///      refuses a time of 0, then a future tick, then an old one, up to the uint256 maximum (docs/MATH.md §6).
    function test_CheckEntryTimeMatchesTheModel() external {
        string memory json = _vectors("checkEntryTime");
        CheckEntryTimeIn[] memory ins = abi.decode(_cases(json, CHECK_ENTRY_TIME_IN), (CheckEntryTimeIn[]));
        _assertCount(json, ".caseCount", ins.length);
        for (uint256 i; i < ins.length; ++i) {
            math.checkEntryTime(ins[i].currentTime, ins[i].publishTime, ins[i].maxAgeSecs, ins[i].clockSkewSecs);
        }
        ins = abi.decode(_reverts(json, CHECK_ENTRY_TIME_IN), (CheckEntryTimeIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            vm.expectRevert(_revertData(errors[i]));
            math.checkEntryTime(ins[i].currentTime, ins[i].publishTime, ins[i].maxAgeSecs, ins[i].clockSkewSecs);
        }
    }

    /// @dev `openGate` lets in exactly what the model does: the owed limit first, then the exposure against free
    ///      money at the market's rate, rounded down, and no exposure test at a rate of 0 (docs/MATH.md §6).
    function test_OpenGateMatchesTheModel() external {
        string memory json = _vectors("openGate");
        OpenGateIn[] memory ins = abi.decode(_cases(json, OPEN_GATE_IN), (OpenGateIn[]));
        _assertCount(json, ".caseCount", ins.length);
        for (uint256 i; i < ins.length; ++i) {
            _openGate(ins[i]);
        }
        ins = abi.decode(_reverts(json, OPEN_GATE_IN), (OpenGateIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            vm.expectRevert(_revertData(errors[i]));
            _openGate(ins[i]);
        }
    }

    /// @dev `fee` rounds down and counts any rate above 100% as 100% (docs/MATH.md §7.3).
    function test_FeeMatchesTheModel() external view {
        string memory json = _vectors("fee");
        FeeCase[] memory cases =
            abi.decode(_cases(json, "FeeCase(uint64 amount,uint16 feeBps,uint64 fee)"), (FeeCase[]));
        _assertCount(json, ".caseCount", cases.length);
        _assertCount(json, ".revertCount", 0);
        for (uint256 i; i < cases.length; ++i) {
            assertEq(math.fee(cases[i].amount, cases[i].feeBps), cases[i].fee, _at("fee", "cases", i));
        }
    }

    /// @dev `winnerFee` is 2% of the profit paid, rounded down: 0 on 49, 1 on 50 (docs/MATH.md §7.3).
    function test_WinnerFeeMatchesTheModel() external view {
        string memory json = _vectors("winnerFee");
        WinnerFeeCase[] memory cases =
            abi.decode(_cases(json, "WinnerFeeCase(uint64 profitPaid,uint64 fee)"), (WinnerFeeCase[]));
        _assertCount(json, ".caseCount", cases.length);
        _assertCount(json, ".revertCount", 0);
        for (uint256 i; i < cases.length; ++i) {
            assertEq(math.winnerFee(cases[i].profitPaid), cases[i].fee, _at("winnerFee", "cases", i));
        }
    }

    /// @dev `loserFee` is 3% of the loss while free money is at or above the floor, and 0 one unit below it
    ///      (docs/MATH.md §7.3).
    function test_LoserFeeMatchesTheModel() external view {
        string memory json = _vectors("loserFee");
        LoserFeeCase[] memory cases = abi.decode(
            _cases(json, "LoserFeeCase(uint64 loss,uint64 freeBefore,uint64 poolFloor,uint64 fee)"), (LoserFeeCase[])
        );
        _assertCount(json, ".caseCount", cases.length);
        _assertCount(json, ".revertCount", 0);
        for (uint256 i; i < cases.length; ++i) {
            LoserFeeCase memory c = cases[i];
            assertEq(math.loserFee(c.loss, c.freeBefore, c.poolFloor), c.fee, _at("loserFee", "cases", i));
        }
    }

    /// @dev `settleSplit`, `toUser` and `outOfPool` split every payout as the model does: the stake back first,
    ///      profit from free money only and only with nobody owed, the rest owed, and both fees (docs/MATH.md §7.4).
    function test_SettleSplitMatchesTheModel() external view {
        string memory json = _vectors("settleSplit");
        SettleSplitIn[] memory ins = abi.decode(_cases(json, SETTLE_SPLIT_IN), (SettleSplitIn[]));
        SettleSplitOut[] memory outs = abi.decode(_cases(json, SETTLE_SPLIT_OUT), (SettleSplitOut[]));
        _assertCount(json, ".caseCount", ins.length);
        _assertCount(json, ".revertCount", 0);
        for (uint256 i; i < ins.length; ++i) {
            SettleSplit memory split = _settleSplit(ins[i]);
            string memory label = _at("settleSplit", "cases", i);
            assertEq(split.own, outs[i].own, string.concat(label, ".own"));
            assertEq(split.paid, outs[i].paid, string.concat(label, ".paid"));
            assertEq(split.owed, outs[i].owed, string.concat(label, ".owed"));
            assertEq(split.winnerFee, outs[i].winnerFee, string.concat(label, ".winnerFee"));
            assertEq(split.loserFee, outs[i].loserFee, string.concat(label, ".loserFee"));
            assertEq(math.toUser(split), outs[i].toUser, string.concat(label, ".toUser"));
            assertEq(math.outOfPool(split), outs[i].outOfPool, string.concat(label, ".outOfPool"));
        }
    }

    /// @dev `checkSellWindow` opens and closes the window at the same second as the model, including a window an
    ///      early end closes and times near the uint256 maximum (docs/MATH.md §8).
    function test_CheckSellWindowMatchesTheModel() external {
        string memory json = _vectors("checkSellWindow");
        CheckSellWindowIn[] memory ins = abi.decode(_cases(json, CHECK_SELL_WINDOW_IN), (CheckSellWindowIn[]));
        _assertCount(json, ".caseCount", ins.length);
        for (uint256 i; i < ins.length; ++i) {
            _checkSellWindow(ins[i]);
        }
        ins = abi.decode(_reverts(json, CHECK_SELL_WINDOW_IN), (CheckSellWindowIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            vm.expectRevert(_revertData(errors[i]));
            _checkSellWindow(ins[i]);
        }
    }

    /// @dev `checkSell` accepts the same quotes and refuses the rest with the same error, each check broken at its
    ///      bound: the payout (which may overflow first), the sale amount, the fee cap, the minimum, the queue and
    ///      the pool's free money (docs/MATH.md §8).
    function test_CheckSellMatchesTheModel() external {
        string memory json = _vectors("checkSell");
        CheckSellIn[] memory ins = abi.decode(_cases(json, CHECK_SELL_IN), (CheckSellIn[]));
        _assertCount(json, ".caseCount", ins.length);
        for (uint256 i; i < ins.length; ++i) {
            _checkSell(ins[i]);
        }
        ins = abi.decode(_reverts(json, CHECK_SELL_IN), (CheckSellIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            vm.expectRevert(_revertData(errors[i]));
            _checkSell(ins[i]);
        }
    }

    /// @dev `sellSplit`, `fees` and `outOfPool` split every sale as the model does, and a sale amount above the
    ///      valuation, which `checkSell` never lets through, panics (docs/MATH.md §8).
    function test_SellSplitMatchesTheModel() external {
        string memory json = _vectors("sellSplit");
        SellSplitIn[] memory ins = abi.decode(_cases(json, SELL_SPLIT_IN), (SellSplitIn[]));
        SellSplitOut[] memory outs = abi.decode(_cases(json, SELL_SPLIT_OUT), (SellSplitOut[]));
        _assertCount(json, ".caseCount", ins.length);
        for (uint256 i; i < ins.length; ++i) {
            SellSplit memory split = _sellSplit(ins[i]);
            string memory label = _at("sellSplit", "cases", i);
            assertEq(split.toUser, outs[i].toUser, string.concat(label, ".toUser"));
            assertEq(split.sellFee, outs[i].sellFee, string.concat(label, ".sellFee"));
            assertEq(split.winnerFee, outs[i].winnerFee, string.concat(label, ".winnerFee"));
            assertEq(split.loserFee, outs[i].loserFee, string.concat(label, ".loserFee"));
            assertEq(math.fees(split), outs[i].fees, string.concat(label, ".fees"));
            assertEq(math.outOfPool(split), outs[i].outOfPool, string.concat(label, ".outOfPool"));
        }
        ins = abi.decode(_reverts(json, SELL_SPLIT_IN), (SellSplitIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            vm.expectRevert(_revertData(errors[i]));
            _sellSplit(ins[i]);
        }
    }

    /// @dev `repaySplit` pays min(owed, free), takes 2% of it, and leaves the rest owed (docs/MATH.md §9).
    function test_RepaySplitMatchesTheModel() external view {
        string memory json = _vectors("repaySplit");
        RepaySplitCase[] memory cases = abi.decode(
            _cases(
                json,
                "RepaySplitCase(uint64 owed,uint64 free,uint64 amount,uint64 winnerFee,uint64 toUser,uint64 remaining)"
            ),
            (RepaySplitCase[])
        );
        _assertCount(json, ".caseCount", cases.length);
        _assertCount(json, ".revertCount", 0);
        for (uint256 i; i < cases.length; ++i) {
            RepaySplitCase memory c = cases[i];
            RepaySplit memory split = math.repaySplit(c.owed, c.free);
            string memory label = _at("repaySplit", "cases", i);
            assertEq(split.amount, c.amount, string.concat(label, ".amount"));
            assertEq(split.winnerFee, c.winnerFee, string.concat(label, ".winnerFee"));
            assertEq(split.toUser, c.toUser, string.concat(label, ".toUser"));
            assertEq(split.remaining, c.remaining, string.concat(label, ".remaining"));
        }
    }

    /// @dev `checkWithdraw` lets out exactly what the model does, and refuses the rest in the same order: a zero
    ///      amount, anyone owed, the floor, the open exposure, then the seed cap, whose `500 × 10^decimals` must fit
    ///      uint64 (docs/MATH.md §10).
    function test_CheckWithdrawMatchesTheModel() external {
        string memory json = _vectors("checkWithdraw");
        CheckWithdrawIn[] memory ins = abi.decode(_cases(json, CHECK_WITHDRAW_IN), (CheckWithdrawIn[]));
        _assertCount(json, ".caseCount", ins.length);
        for (uint256 i; i < ins.length; ++i) {
            _checkWithdraw(ins[i]);
        }
        ins = abi.decode(_reverts(json, CHECK_WITHDRAW_IN), (CheckWithdrawIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            vm.expectRevert(_revertData(errors[i]));
            _checkWithdraw(ins[i]);
        }
    }

    function _lines(LinesIn memory x) private view returns (int64, int64) {
        return math.lines(x.entry, Side(x.side), x.leverage, x.thetaE7, x.capBps);
    }

    function _capLine(CapLineIn memory x) private view returns (int64) {
        return math.capLine(x.entry, Side(x.side), x.leverage, x.capBps);
    }

    function _gBps(GBpsIn memory x) private view returns (uint16) {
        return math.gBps(x.entry, x.price, Side(x.side), x.leverage, x.floorBps, x.capBps);
    }

    function _checkLiquidation(CheckLiquidationIn memory x) private view {
        math.checkLiquidation({
            positionId: bytes32(x.positionId),
            startTime: x.startTime,
            endTime: x.endTime,
            liqPrice: x.liqPrice,
            side: Side(x.side),
            price: x.price,
            publishTime: x.publishTime,
            currentTime: x.currentTime,
            clockSkewSecs: x.clockSkewSecs
        });
    }

    function _openGate(OpenGateIn memory x) private view {
        math.openGate(x.totalOwed, x.maxTotalOwed, x.openMaxProfit, x.newMaxProfit, x.free, x.maxExposureBps);
    }

    function _settleSplit(SettleSplitIn memory x) private view returns (SettleSplit memory) {
        return math.settleSplit(x.payoutAmount, x.stake, x.freeBefore, x.totalOwed, x.poolFloor);
    }

    function _checkSellWindow(CheckSellWindowIn memory x) private view {
        math.checkSellWindow(x.startTime, x.endTime, x.publishTime, x.minDelaySecs, x.cutoffSecs);
    }

    function _checkSell(CheckSellIn memory x) private view {
        math.checkSell({
            stake: x.stake,
            gNowBps: x.gNowBps,
            valuation: x.valuation,
            sellAmount: x.sellAmount,
            minAmount: x.minAmount,
            maxSellFeeBps: x.maxSellFeeBps,
            totalOwed: x.totalOwed,
            freeBefore: x.freeBefore
        });
    }

    function _sellSplit(SellSplitIn memory x) private view returns (SellSplit memory) {
        return math.sellSplit(x.stake, x.valuation, x.sellAmount, x.freeBefore, x.poolFloor);
    }

    function _checkWithdraw(CheckWithdrawIn memory x) private view {
        math.checkWithdraw({
            purpose: WithdrawPurpose(x.purpose),
            amount: x.amount,
            free: x.free,
            totalOwed: x.totalOwed,
            poolFloor: x.poolFloor,
            openMaxProfit: x.openMaxProfit,
            seedRecovered: x.seedRecovered,
            decimals: x.decimals
        });
    }
}

/// @title ConfigLib_ModelVectors_Test
/// @notice `ConfigLib.validate` and `ConfigLib.validateOpen` against the reference model's vectors: the same settings
///         and the same terms accepted, and the rest refused with the same error.
/// @dev `validate`'s every refusal is `InvalidLeverageParams`, so its vectors cover each of the eleven rules on its
///      bound and one unit past it, at each tier and at any leverage. `validateOpen` reads a stored market: the file
///      lists the markets, each case names one, and the harness stores it with `setMarket` before the case runs.
contract ConfigLib_ModelVectors_Test is ModelVectors_Shared_Test {
    /// @dev A market's settings at a leverage, for `validate`.
    struct ValidateIn {
        ConfigParams p;
        uint16 leverage;
    }

    /// @dev A bet's terms on market `market` (its index in the file's `markets`), for `validateOpen`.
    struct ValidateOpenIn {
        uint256 market;
        uint64 stake;
        uint16 durationSecs;
        uint32 thetaE7;
        uint16 floorBps;
        uint16 capBps;
    }

    /// @dev `ConfigParams` and `DurationRule`, field for field as in src/types (the order the ABI encodes them in).
    string internal constant CONFIG_PARAMS = "ConfigParams(bool enabled,uint8 entryMaxAgeSecs,uint8 clockSkewSecs,"
        "uint16 floorMinBps,uint16 floorMaxBps,uint16 capMinBps,uint16 capMaxBps,uint16 maxSellFeeBps,"
        "uint16 sellMinDelaySecs,uint16 sellCutoffSecs,uint32 maxExposureBps,uint64 minStake,uint64 maxStake,"
        "uint64 maxTotalOwed,DurationRule[5] durations)"
        "DurationRule(uint16 durationSecs,uint32 thetaMinE7,uint32 thetaMaxE7,bool enabled)";
    string internal constant VALIDATE_OPEN_IN = "ValidateOpenIn(uint256 market,uint64 stake,uint16 durationSecs,"
        "uint32 thetaE7,uint16 floorBps,uint16 capBps)";

    ConfigLibHarness internal lib;

    function setUp() public {
        lib = new ConfigLibHarness();
    }

    /// @dev `validate` accepts exactly the settings the model accepts: the example market, the three tiers'
    ///      settings, every rule of docs/MATH.md §3.1 on its bound and one unit past it, and random settings at
    ///      every leverage, with zero, one or two settings moved.
    function test_ValidateMatchesTheModel() external {
        string memory json = _vectors("validate");
        string memory inType = string.concat("ValidateIn(ConfigParams p,uint16 leverage)", CONFIG_PARAMS);
        ValidateIn[] memory ins = abi.decode(_cases(json, inType), (ValidateIn[]));
        _assertCount(json, ".caseCount", ins.length);
        for (uint256 i; i < ins.length; ++i) {
            lib.validate(ins[i].p, ins[i].leverage);
        }
        ins = abi.decode(_reverts(json, inType), (ValidateIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            vm.expectRevert(_revertData(errors[i]));
            lib.validate(ins[i].p, ins[i].leverage);
        }
    }

    /// @dev `validateOpen` accepts exactly the terms the model accepts on each stored market, and refuses the rest
    ///      in the same order: the stake, the duration's enabled rule, its theta, the floor, then the cap, whose
    ///      lowest is the floor when that is higher (docs/MATH.md §3.2).
    function test_ValidateOpenMatchesTheModel() external {
        string memory json = _vectors("validateOpen");
        ConfigParams[] memory markets =
            abi.decode(vm.parseJsonTypeArray(json, ".markets", CONFIG_PARAMS), (ConfigParams[]));
        ValidateOpenIn[] memory ins = abi.decode(_cases(json, VALIDATE_OPEN_IN), (ValidateOpenIn[]));
        _assertCount(json, ".caseCount", ins.length);
        uint256 stored = type(uint256).max;
        for (uint256 i; i < ins.length; ++i) {
            stored = _store(markets, ins[i].market, stored);
            _validateOpen(ins[i]);
        }
        ins = abi.decode(_reverts(json, VALIDATE_OPEN_IN), (ValidateOpenIn[]));
        string[] memory errors = _errorNames(json);
        for (uint256 i; i < ins.length; ++i) {
            stored = _store(markets, ins[i].market, stored);
            vm.expectRevert(_revertData(errors[i]));
            _validateOpen(ins[i]);
        }
    }

    /// @dev Stores market `index` in the harness unless it is the one stored already; returns the stored index.
    function _store(ConfigParams[] memory markets, uint256 index, uint256 stored) private returns (uint256) {
        if (index != stored) lib.setMarket(markets[index]);
        return index;
    }

    function _validateOpen(ValidateOpenIn memory x) private view {
        lib.validateOpen(x.stake, x.durationSecs, x.thetaE7, x.floorBps, x.capBps);
    }
}
