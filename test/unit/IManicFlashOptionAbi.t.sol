// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {IManicFlashOptionAdmin} from "../../src/interfaces/IManicFlashOptionAdmin.sol";
import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../src/interfaces/IManicFlashOptionEvents.sol";
import {IManicFlashOptionPool} from "../../src/interfaces/IManicFlashOptionPool.sol";
import {IManicFlashOptionRoles as Roles} from "../../src/interfaces/IManicFlashOptionRoles.sol";
import {IManicFlashOptionSettlement} from "../../src/interfaces/IManicFlashOptionSettlement.sol";
import {IManicFlashOptionTrading} from "../../src/interfaces/IManicFlashOptionTrading.sol";
import {IManicFlashOptionViews} from "../../src/interfaces/IManicFlashOptionViews.sol";

/// @title IManicFlashOptionAbi_Unit_Test
/// @notice Pins the contract's ABI: every function's selector, every event's topic and every error's selector must
///         equal the hash of its canonical signature. The interface must hold exactly these 42 functions, 22 events
///         and 52 errors, plus OpenZeppelin's role-management and EIP-712 domain interfaces. The backend calls, and
///         decodes logs and reverts, by these values, so none may change by accident.
/// @dev A signature is the name plus the argument types in order: enums encode as `uint8`, and a struct as the tuple
///      of its fields, so `ConfigUpdated` also pins every field of `ConfigParams`. Changing a pinned value is an ABI
///      change: update this test, regenerate `abi/IManicFlashOption.json`, note it in CHANGELOG.md, and tell the
/// backend (docs/CONVENTIONS.md §6). Swapping two fields of the same type keeps the signature but changes the names in
///      the committed ABI, which CI diffs. The events and errors are listed in docs/ARCHITECTURE.md §11.
contract IManicFlashOptionAbi_Unit_Test is Test {
    /// @dev The compiled interface, read for its ABI. `forge test` builds it first.
    string internal constant ARTIFACT = "out/IManicFlashOption.sol/IManicFlashOption.json";

    /// @dev Every function of ours keeps its signature, so its selector never changes. `initialize` takes the
    ///      `InitParams` tuple, so its selector also pins every field of `InitParams`.
    function test_EveryFunctionKeepsItsSelector() public pure {
        _function(
            IManicFlashOptionAdmin.initialize.selector,
            "initialize((address,uint48,address,address,address,address[],address[],address,uint64,address,address,"
            "uint48,uint64,uint32))"
        );
        _function(
            IManicFlashOptionAdmin.createMarket.selector,
            "createMarket(bytes32,uint16,int8,(bool,uint8,uint8,uint16,uint16,uint16,uint16,uint16,uint16,uint16,"
            "uint32,uint64,uint64,uint64,(uint16,uint32,uint32,bool)[5]))"
        );
        _function(
            IManicFlashOptionAdmin.setConfig.selector,
            "setConfig(bytes32,uint16,(bool,uint8,uint8,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,"
            "uint64,uint64,uint64,(uint16,uint32,uint32,bool)[5]))"
        );
        _function(IManicFlashOptionAdmin.setPaused.selector, "setPaused(bytes32,uint16,bool)");
        _function(IManicFlashOptionAdmin.setHalted.selector, "setHalted(bool)");
        _function(IManicFlashOptionAdmin.setPoolFloor.selector, "setPoolFloor(uint64)");
        _function(IManicFlashOptionAdmin.setRecipients.selector, "setRecipients(address,address)");
        _function(IManicFlashOptionAdmin.setRefundDelay.selector, "setRefundDelay(uint48)");
        _function(IManicFlashOptionAdmin.setBreaker.selector, "setBreaker(uint64,uint32)");
        _function(IManicFlashOptionAdmin.resetBreaker.selector, "resetBreaker()");
        _function(IManicFlashOptionAdmin.revokeRelayer.selector, "revokeRelayer(bytes32,address)");
        _function(
            IManicFlashOptionTrading.open.selector,
            "open((bytes32,address,bytes32,uint16,uint8,uint64,uint16,uint48,uint48),bytes,"
            "(int64,uint48,uint32,uint16,uint16),(uint256,uint256,bytes))"
        );
        _function(
            IManicFlashOptionTrading.sell.selector,
            "sell((bytes32,uint64,uint48,uint48),bytes,(int64,uint48,uint64,uint64))"
        );
        _function(IManicFlashOptionSettlement.liquidate.selector, "liquidate(bytes32,uint16,int64,uint48,bytes32[])");
        _function(IManicFlashOptionSettlement.settle.selector, "settle(bytes32,uint16,int64,uint48,bytes32[])");
        _function(IManicFlashOptionSettlement.refundExpired.selector, "refundExpired(bytes32[])");
        _function(IManicFlashOptionSettlement.repay.selector, "repay(uint256)");
        _function(IManicFlashOptionPool.fund.selector, "fund(uint64)");
        _function(IManicFlashOptionPool.withdraw.selector, "withdraw(uint8,uint64)");
        _function(IManicFlashOptionPool.claim.selector, "claim(address)");
        _function(IManicFlashOptionPool.sweepFees.selector, "sweepFees()");
        _function(Roles.UPGRADER_ROLE.selector, "UPGRADER_ROLE()");
        _function(Roles.OPERATOR_ROLE.selector, "OPERATOR_ROLE()");
        _function(Roles.GUARDIAN_ROLE.selector, "GUARDIAN_ROLE()");
        _function(Roles.OPENER_ROLE.selector, "OPENER_ROLE()");
        _function(Roles.SETTLER_ROLE.selector, "SETTLER_ROLE()");
    }

    /// @dev Every read-only function keeps its signature too: the getters, the hash helpers and `version`.
    function test_EveryViewKeepsItsSelector() public pure {
        _function(
            IManicFlashOptionViews.hashOpenOrder.selector,
            "hashOpenOrder((bytes32,address,bytes32,uint16,uint8,uint64,uint16,uint48,uint48))"
        );
        _function(IManicFlashOptionViews.hashSellOrder.selector, "hashSellOrder((bytes32,uint64,uint48,uint48))");
        _function(IManicFlashOptionViews.getPosition.selector, "getPosition(bytes32)");
        _function(IManicFlashOptionViews.getMarket.selector, "getMarket(bytes32,uint16)");
        _function(IManicFlashOptionViews.marketIdAt.selector, "marketIdAt(uint16)");
        _function(IManicFlashOptionViews.marketCount.selector, "marketCount()");
        _function(IManicFlashOptionViews.getPool.selector, "getPool()");
        _function(IManicFlashOptionViews.freeMoney.selector, "freeMoney()");
        _function(IManicFlashOptionViews.claimableOf.selector, "claimableOf(address)");
        _function(IManicFlashOptionViews.queueHead.selector, "queueHead()");
        _function(IManicFlashOptionViews.getBreaker.selector, "getBreaker()");
        _function(IManicFlashOptionViews.token.selector, "token()");
        _function(IManicFlashOptionViews.halted.selector, "halted()");
        _function(IManicFlashOptionViews.refundDelaySecs.selector, "refundDelaySecs()");
        _function(IManicFlashOptionViews.recipients.selector, "recipients()");
        _function(IManicFlashOptionViews.version.selector, "version()");
    }

    /// @dev Every event keeps its signature, so its log topic never changes.
    function test_EveryEventKeepsItsSignature() public pure {
        // Positions
        _event(
            Events.PositionOpened.selector,
            "PositionOpened(bytes32,address,bytes32,uint8,uint64,int64,int8,int64,int64,uint32,uint16,uint16,"
            "uint48,uint48,uint16)"
        );
        _event(
            Events.PositionLiquidated.selector,
            "PositionLiquidated(bytes32,address,uint8,uint64,int64,int64,uint48,uint48,uint64,uint16)"
        );
        _event(
            Events.PositionSettled.selector,
            "PositionSettled(bytes32,address,uint8,uint64,int64,uint48,uint16,uint64,uint64,uint64,uint64,uint64,"
            "uint64,uint16)"
        );
        _event(
            Events.PositionSold.selector,
            "PositionSold(bytes32,address,uint8,uint64,int64,uint48,uint16,uint64,uint64,uint64,uint64,uint64,"
            "uint16)"
        );
        _event(Events.OwedRepaid.selector, "OwedRepaid(bytes32,address,uint64,uint64,uint64,uint64)");
        _event(Events.PositionSkipped.selector, "PositionSkipped(bytes32,uint8)");
        _event(Events.PositionRefunded.selector, "PositionRefunded(bytes32,address,uint64)");
        // The pool
        _event(Events.PoolFunded.selector, "PoolFunded(address,uint64)");
        _event(Events.PoolWithdrawn.selector, "PoolWithdrawn(uint8,uint64,address)");
        _event(Events.PayoutDeferred.selector, "PayoutDeferred(bytes32,address,uint64)");
        _event(Events.Claimed.selector, "Claimed(address,uint64)");
        _event(Events.FeesSwept.selector, "FeesSwept(address,uint64)");
        // Markets and settings; the tuple is ConfigParams, field by field
        _event(Events.MarketCreated.selector, "MarketCreated(bytes32,uint16,uint16,int8)");
        _event(
            Events.ConfigUpdated.selector,
            "ConfigUpdated(bytes32,uint16,address,(bool,uint8,uint8,uint16,uint16,uint16,uint16,uint16,uint16,uint16,"
            "uint32,uint64,uint64,uint64,(uint16,uint32,uint32,bool)[5]))"
        );
        _event(Events.PauseChanged.selector, "PauseChanged(bytes32,uint16,address,bool)");
        _event(Events.HaltChanged.selector, "HaltChanged(address,bool)");
        _event(Events.PoolFloorUpdated.selector, "PoolFloorUpdated(uint64)");
        _event(Events.RecipientsUpdated.selector, "RecipientsUpdated(address,address)");
        _event(Events.RefundDelayUpdated.selector, "RefundDelayUpdated(uint48)");
        // The payout circuit breaker
        _event(Events.CircuitBreakerUpdated.selector, "CircuitBreakerUpdated(uint64,uint32)");
        _event(Events.CircuitBreakerTripped.selector, "CircuitBreakerTripped(uint64,uint64,uint48)");
        _event(Events.CircuitBreakerReset.selector, "CircuitBreakerReset(address)");
    }

    /// @dev Every error of the switches, orders, prices and price times keeps its signature, so its selector never
    ///      changes. Errors raised for one position inside a batch carry its id (`bytes32`).
    function test_TheSwitchOrderAndPriceErrorsKeepTheirSignatures() public pure {
        // Switches and markets
        _error(Errors.Halted.selector, "Halted()");
        _error(Errors.UnknownMarket.selector, "UnknownMarket()");
        _error(Errors.LeverageDisabled.selector, "LeverageDisabled()");
        _error(Errors.LeveragePaused.selector, "LeveragePaused()");
        _error(Errors.BreakerTripped.selector, "BreakerTripped()");
        // Orders and signatures
        _error(Errors.OrderExpired.selector, "OrderExpired()");
        _error(Errors.PositionIdUsed.selector, "PositionIdUsed()");
        _error(Errors.InvalidSignature.selector, "InvalidSignature()");
        _error(Errors.PriceBeforeOrder.selector, "PriceBeforeOrder()");
        _error(Errors.TransferAmountMismatch.selector, "TransferAmountMismatch(uint256,uint256)");
        // Prices and parameters
        _error(Errors.InvalidPrice.selector, "InvalidPrice()");
        _error(Errors.InvalidLeverageParams.selector, "InvalidLeverageParams()");
        _error(Errors.MathOverflow.selector, "MathOverflow()");
        _error(Errors.InvalidAmount.selector, "InvalidAmount()");
        // Price times
        _error(Errors.PriceTooOld.selector, "PriceTooOld()");
        _error(Errors.PriceFromFuture.selector, "PriceFromFuture()");
        _error(Errors.InvalidLiquidationWindow.selector, "InvalidLiquidationWindow(bytes32)");
        _error(Errors.LiquidationPriceNotReached.selector, "LiquidationPriceNotReached(bytes32)");
        _error(Errors.InvalidPriceTimestamp.selector, "InvalidPriceTimestamp(bytes32)");
        _error(Errors.NotExpired.selector, "NotExpired()");
        _error(Errors.LiquidateInstead.selector, "LiquidateInstead(bytes32)");
    }

    /// @dev Every error of the positions, batches, opening, selling, repaying, payouts, withdrawals and admin keeps its
    ///      signature, so its selector never changes.
    function test_ThePositionPoolAndAdminErrorsKeepTheirSignatures() public pure {
        // Positions and batches
        _error(Errors.UnknownPosition.selector, "UnknownPosition(bytes32)");
        _error(Errors.ConfigMismatch.selector, "ConfigMismatch(bytes32)");
        _error(Errors.PositionNotOpen.selector, "PositionNotOpen()");
        _error(Errors.EmptyBatch.selector, "EmptyBatch()");
        _error(Errors.BatchSizeTooLarge.selector, "BatchSizeTooLarge()");
        // Opening
        _error(Errors.OpenBlockedTotalOwed.selector, "OpenBlockedTotalOwed()");
        _error(Errors.OpenBlockedExposure.selector, "OpenBlockedExposure()");
        // Selling
        _error(Errors.SellWindowClosed.selector, "SellWindowClosed()");
        _error(Errors.ValuationAboveCurrentPayout.selector, "ValuationAboveCurrentPayout()");
        _error(Errors.SellAmountExceedsValuation.selector, "SellAmountExceedsValuation()");
        _error(Errors.SellFeeTooHigh.selector, "SellFeeTooHigh()");
        _error(Errors.SellAmountBelowMin.selector, "SellAmountBelowMin()");
        _error(Errors.QueueNotEmpty.selector, "QueueNotEmpty()");
        _error(Errors.SellNotPayable.selector, "SellNotPayable()");
        // Repaying and refunding
        _error(Errors.InvalidMaxCount.selector, "InvalidMaxCount()");
        _error(Errors.RefundDisabled.selector, "RefundDisabled()");
        _error(Errors.RefundTooEarly.selector, "RefundTooEarly(bytes32)");
        // Payouts and claims
        _error(Errors.InsufficientGasForPayout.selector, "InsufficientGasForPayout()");
        _error(Errors.NothingToClaim.selector, "NothingToClaim()");
        // Withdrawing
        _error(Errors.OwedOutstanding.selector, "OwedOutstanding()");
        _error(Errors.BelowPoolFloor.selector, "BelowPoolFloor()");
        _error(Errors.OpenExposureNotCovered.selector, "OpenExposureNotCovered()");
        _error(Errors.SeedRecoveryExceeded.selector, "SeedRecoveryExceeded()");
        // Admin
        _error(Errors.ZeroAddress.selector, "ZeroAddress()");
        _error(Errors.InvalidTokenDecimals.selector, "InvalidTokenDecimals(uint8)");
        _error(Errors.InvalidRefundDelay.selector, "InvalidRefundDelay()");
        _error(Errors.MarketExists.selector, "MarketExists()");
        _error(Errors.OnlyOperatorCanUnpause.selector, "OnlyOperatorCanUnpause()");
        _error(Errors.OnlyOperatorCanUnhalt.selector, "OnlyOperatorCanUnhalt()");
        _error(Errors.InvalidRelayerRole.selector, "InvalidRelayerRole(bytes32)");
        _error(Errors.InvalidBreakerParams.selector, "InvalidBreakerParams()");
    }

    /// @dev The compiled interface holds exactly what is pinned above, plus OpenZeppelin's interfaces, and nothing
    ///      else, so nothing can be added without a pin:
    ///      - functions: our 42, plus 16 from `IAccessControlDefaultAdminRules` (with `IAccessControl`) and `IERC5267`;
    ///      - events: our 22, plus their 8 (the role, admin-transfer and domain events);
    ///      - errors: our 52, plus their 5 (`AccessControlUnauthorizedAccount` and the admin-rule errors).
    function test_TheInterfaceHoldsExactlyThePinnedEntries() public view {
        string[] memory entryTypes = abi.decode(vm.parseJson(vm.readFile(ARTIFACT), "$.abi[*].type"), (string[]));
        uint256 functions;
        uint256 events;
        uint256 errors;
        for (uint256 i; i < entryTypes.length; ++i) {
            bytes32 entryType = keccak256(bytes(entryTypes[i]));
            if (entryType == keccak256("function")) ++functions;
            else if (entryType == keccak256("event")) ++events;
            else if (entryType == keccak256("error")) ++errors;
        }
        assertEq(functions, 42 + 16, "functions");
        assertEq(events, 22 + 8, "events");
        assertEq(errors, 52 + 5, "errors");
        assertEq(entryTypes.length, functions + events + errors, "nothing but functions, events and errors");
    }

    /// @dev A function's selector is the first 4 bytes of the keccak256 of its signature.
    function _function(bytes4 selector, string memory signature) internal pure {
        assertEq(selector, bytes4(keccak256(bytes(signature))), signature);
    }

    /// @dev An event's selector is its log's first topic: the keccak256 of its signature.
    function _event(bytes32 topic, string memory signature) internal pure {
        assertEq(topic, keccak256(bytes(signature)), signature);
    }

    /// @dev An error's selector is the first 4 bytes of the keccak256 of its signature.
    function _error(bytes4 selector, string memory signature) internal pure {
        assertEq(selector, bytes4(keccak256(bytes(signature))), signature);
    }
}
