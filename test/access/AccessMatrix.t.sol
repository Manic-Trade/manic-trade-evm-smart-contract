// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {ManicFlashOption} from "../../src/ManicFlashOption.sol";
import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, SellOrder} from "../../src/types/OrderTypes.sol";
import {Position, Side, WithdrawPurpose} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {Defaults} from "../utils/Defaults.sol";
import {Examples} from "../utils/Examples.sol";

/// @title AccessMatrix_Test
/// @notice Who may call what (docs/ARCHITECTURE.md §4.2, security checklist AC-1 and AC-4): every function that
///         changes state, called by each of the 11 test users, against one table of who it lets through.
/// @dev The table is `_rows()`: one row per function, pausing and unpausing, halting and unhalting apart, since
///      different roles may do each. A row names its function as the ABI does, its gate, and a builder that sets up
///      what the call needs to go through (a bet to sell, an IOU to repay, a pending admin transfer to accept) and
///      returns its calldata. For every row and every user, from the same state:
///      - a user the gate lets through must succeed: the gate is right, and nothing else in the set-up refuses them;
///      - every other user must be refused with the gate's exact error, the role named included.
///      `test_TheTableListsEveryFunctionThatChangesState` holds the table to the compiled contract's ABI, so a new
///      function can't be added without a row. Each function's own tests (`test/concrete/<function>/`) refuse a wrong
///      caller too; this table checks them as a whole, against the role map.
///
///      | Gate | Who it lets through | Everyone else gets |
///      |---|---|---|
///      | Admin | `DEFAULT_ADMIN_ROLE` (the timelock on mainnet) | `AccessControlUnauthorizedAccount(caller, role)` |
///      | Upgrader | `UPGRADER_ROLE` (the timelock on mainnet) | the same |
///      | Operator | `OPERATOR_ROLE` (the admin Safe) | the same |
///      | Guardian | `GUARDIAN_ROLE` | the same |
///      | GuardianOrOperator | the guardian or the operator (to pause or halt) | the same, naming `GUARDIAN_ROLE` |
///      | OperatorToUnpause | the operator only, not the guardian | `OnlyOperatorCanUnpause()` |
///      | OperatorToUnhalt | the operator only, not the guardian | `OnlyOperatorCanUnhalt()` |
///      | Opener / Settler | the relayer keys | `AccessControlUnauthorizedAccount(caller, role)` |
///      | PendingAdmin | the account the admin role was offered to | `AccessControlInvalidDefaultAdmin(caller)` |
///      | TheHolderItself | the account renouncing its own role | `AccessControlBadConfirmation()` |
///      | Nobody | no one: `initialize` ran in the deploy transaction | `InvalidInitialization()` |
///      | Anyone | every user | — |
contract AccessMatrix_Test is Settlement_Base_Test {
    /// @dev Who a row's function lets through. Each gate refuses everyone else with one exact error (above).
    enum Gate {
        Admin,
        Upgrader,
        Operator,
        Guardian,
        GuardianOrOperator,
        OperatorToUnpause,
        OperatorToUnhalt,
        Opener,
        Settler,
        PendingAdmin,
        TheHolderItself,
        Nobody,
        Anyone
    }

    /// @dev One function, its gate, and the builder that sets up the call and returns its calldata. The builder is
    ///      given the caller, for the one row whose set-up depends on it (`fund`: the caller's own USDG, approved).
    struct Row {
        string name;
        Gate gate;
        function(address) internal returns (bytes memory) call;
    }

    // The role ids, computed here rather than read from the contract, so a wrong id there fails here.
    bytes32 internal constant ADMIN_ROLE = 0x00;
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant OPENER_ROLE = keccak256("OPENER_ROLE");
    bytes32 internal constant SETTLER_ROLE = keccak256("SETTLER_ROLE");

    /// @dev A feed with no market yet, for `createMarket`.
    bytes32 internal constant ETH = keccak256("ETH/USD");

    /// @dev The base bet sold at +$8 at once: valued $12.50, sold for $12.
    uint64 internal constant SALE_VALUATION = 12_500_000;
    uint64 internal constant SALE_AMOUNT = 12_000_000;
    uint64 internal constant SALE_MIN = 11_640_000;

    /// @dev The number of functions that change state: the 29 of `IManicFlashOption` and `upgradeToAndCall`.
    uint256 internal constant FUNCTIONS = 30;

    /// @dev Another implementation, for the upgrader's `upgradeToAndCall`.
    ManicFlashOption internal nextImplementation;

    /// @dev Each row's calldata as built for eve after `setUp`, without the state the builder set up: what the fuzz
    ///      test sends. A role check runs first, so a caller it refuses is refused whatever the state.
    bytes[] internal plainCalls;

    function setUp() public override {
        super.setUp();
        nextImplementation = new ManicFlashOption();
        Row[] memory rows = _rows();
        for (uint256 i; i < rows.length; ++i) {
            uint256 state = vm.snapshotState();
            bytes memory data = rows[i].call(users.eve);
            vm.revertToStateAndDelete(state);
            plainCalls.push(data);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The tests
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Every function, called by each of the 11 users from the same state: the gate's users succeed, everyone
    ///      else is refused with its exact error.
    function test_EveryFunctionLetsThroughOnlyItsCallers() external {
        Row[] memory rows = _rows();
        address[11] memory callers = _everyone();
        for (uint256 i; i < rows.length; ++i) {
            for (uint256 j; j < callers.length; ++j) {
                _checkCell(rows[i], callers[j]);
            }
        }
    }

    /// @dev The table and the compiled contract list the same functions that change state, so a function added later
    ///      without a row fails here. `upgradeToAndCall` is the implementation's own, so the ABI read is the
    ///      implementation's artifact, not `abi/IManicFlashOption.json`.
    function test_TheTableListsEveryFunctionThatChangesState() external view {
        string memory artifact = vm.readFile("out/ManicFlashOption.sol/ManicFlashOption.json");
        // A filter matches many values: `parseJson` returns them together, as one ABI-encoded array.
        string[] memory changing = abi.decode(
            vm.parseJson(
                artifact,
                "$.abi[?(@.type == 'function' && @.stateMutability != 'view' && @.stateMutability != 'pure')].name"
            ),
            (string[])
        );
        assertEq(changing.length, FUNCTIONS, "functions that change state");
        Row[] memory rows = _rows();
        for (uint256 i; i < changing.length; ++i) {
            assertTrue(_hasRow(rows, changing[i]), string.concat("no row for ", changing[i]));
        }
        for (uint256 i; i < rows.length; ++i) {
            assertTrue(_isIn(changing, rows[i].name), string.concat("not in the ABI: ", rows[i].name));
        }
    }

    /// @dev Any address that holds no role is refused by every function that needs one, with the gate's exact error.
    function testFuzz_AnAddressWithoutARoleIsRefusedEverywhere(address caller) external {
        _assumeNoPower(caller);
        Row[] memory rows = _rows();
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].gate == Gate.Anyone) continue;
            vm.prank(caller);
            (bool ok, bytes memory returned) = address(flashOption).call(plainCalls[i]);
            assertFalse(ok, rows[i].name);
            assertEq(returned, _refusal(rows[i].gate, caller), rows[i].name);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The table
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Who may call what: docs/ARCHITECTURE.md §4.2's role map, function by function.
    function _rows() private pure returns (Row[] memory r) {
        r = new Row[](32);
        // Trading and the endings: the relayer keys, and anyone for the refund and the repayment queue.
        r[0] = Row("open", Gate.Opener, _callOpen);
        r[1] = Row("sell", Gate.Opener, _callSell);
        r[2] = Row("liquidate", Gate.Settler, _callLiquidate);
        r[3] = Row("settle", Gate.Settler, _callSettle);
        r[4] = Row("refundExpired", Gate.Anyone, _callRefundExpired);
        r[5] = Row("repay", Gate.Anyone, _callRepay);
        // Money in and out: anyone adds to the pool, claims for an account, or sweeps fees to the fee recipient.
        r[6] = Row("fund", Gate.Anyone, _callFund);
        r[7] = Row("claim", Gate.Anyone, _callClaim);
        r[8] = Row("sweepFees", Gate.Anyone, _callSweepFees);
        r[9] = Row("withdraw", Gate.Admin, _callWithdraw);
        // The markets and the brakes.
        r[10] = Row("createMarket", Gate.Admin, _callCreateMarket);
        r[11] = Row("setConfig", Gate.Operator, _callSetConfig);
        r[12] = Row("setPaused", Gate.GuardianOrOperator, _callPause);
        r[13] = Row("setPaused", Gate.OperatorToUnpause, _callUnpause);
        r[14] = Row("setHalted", Gate.GuardianOrOperator, _callHalt);
        r[15] = Row("setHalted", Gate.OperatorToUnhalt, _callUnhalt);
        r[16] = Row("resetBreaker", Gate.Operator, _callResetBreaker);
        r[17] = Row("revokeRelayer", Gate.Guardian, _callRevokeRelayer);
        // The pool's settings: the admin.
        r[18] = Row("setPoolFloor", Gate.Admin, _callSetPoolFloor);
        r[19] = Row("setRecipients", Gate.Admin, _callSetRecipients);
        r[20] = Row("setRefundDelay", Gate.Admin, _callSetRefundDelay);
        r[21] = Row("setBreaker", Gate.Admin, _callSetBreaker);
        // The roles (OpenZeppelin's AccessControlDefaultAdminRules).
        r[22] = Row("grantRole", Gate.Admin, _callGrantRole);
        r[23] = Row("revokeRole", Gate.Admin, _callRevokeRole);
        r[24] = Row("renounceRole", Gate.TheHolderItself, _callRenounceRole);
        r[25] = Row("beginDefaultAdminTransfer", Gate.Admin, _callBeginAdminTransfer);
        r[26] = Row("cancelDefaultAdminTransfer", Gate.Admin, _callCancelAdminTransfer);
        r[27] = Row("acceptDefaultAdminTransfer", Gate.PendingAdmin, _callAcceptAdminTransfer);
        r[28] = Row("changeDefaultAdminDelay", Gate.Admin, _callChangeAdminDelay);
        r[29] = Row("rollbackDefaultAdminDelay", Gate.Admin, _callRollbackAdminDelay);
        // Set-up and code.
        r[30] = Row("initialize", Gate.Nobody, _callInitialize);
        r[31] = Row("upgradeToAndCall", Gate.Upgrader, _callUpgrade);
    }

    /// @dev Whether `gate` lets `caller` through.
    function _lets(Gate gate, address caller) private view returns (bool) {
        if (gate == Gate.Anyone) return true;
        if (gate == Gate.Nobody) return false;
        if (gate == Gate.GuardianOrOperator) return caller == users.guardian || caller == users.operator;
        return caller == _holder(gate);
    }

    /// @dev The one user a single-holder gate lets through.
    function _holder(Gate gate) private view returns (address) {
        if (gate == Gate.Admin) return users.admin;
        if (gate == Gate.Upgrader) return users.upgrader;
        if (gate == Gate.Guardian) return users.guardian;
        if (gate == Gate.Opener || gate == Gate.TheHolderItself) return users.opener; // renouncing the opener role
        if (gate == Gate.Settler) return users.settler;
        if (gate == Gate.PendingAdmin) return users.bob; // offered the admin role by `_callAcceptAdminTransfer`
        return users.operator; // Operator, OperatorToUnpause, OperatorToUnhalt
    }

    /// @dev The exact revert data `gate` refuses `caller` with.
    function _refusal(Gate gate, address caller) private pure returns (bytes memory) {
        if (gate == Gate.OperatorToUnpause) return abi.encodeWithSelector(Errors.OnlyOperatorCanUnpause.selector);
        if (gate == Gate.OperatorToUnhalt) return abi.encodeWithSelector(Errors.OnlyOperatorCanUnhalt.selector);
        if (gate == Gate.PendingAdmin) {
            return
                abi.encodeWithSelector(
                    IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, caller
                );
        }
        if (gate == Gate.TheHolderItself) {
            return abi.encodeWithSelector(IAccessControl.AccessControlBadConfirmation.selector);
        }
        if (gate == Gate.Nobody) return abi.encodeWithSelector(Initializable.InvalidInitialization.selector);
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, _role(gate));
    }

    /// @dev The role a role gate names in its refusal. Pausing and halting name the guardian's, the role made for them.
    function _role(Gate gate) private pure returns (bytes32) {
        if (gate == Gate.Admin) return ADMIN_ROLE;
        if (gate == Gate.Upgrader) return UPGRADER_ROLE;
        if (gate == Gate.Operator) return OPERATOR_ROLE;
        if (gate == Gate.Opener) return OPENER_ROLE;
        if (gate == Gate.Settler) return SETTLER_ROLE;
        return GUARDIAN_ROLE; // Guardian, GuardianOrOperator
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The builders: each sets up what its call needs to go through, and returns the calldata
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Alice's base order, signed, with her stake authorised and minted.
    function _callOpen(address) private returns (bytes memory) {
        OpenOrder memory o = _order(users.alice, "matrix");
        _mintUsdg(o.user, o.stake);
        return abi.encodeCall(
            flashOption.open, (o, _signOrder(flashOption, aliceKey, o), _terms(), _stakeAuth(flashOption, aliceKey, o))
        );
    }

    /// @dev Alice's open bet, and her signed order to sell it at once at +$8.
    function _callSell(address) private returns (bytes memory) {
        _bet(users.alice, "matrix", Side.Call);
        SellOrder memory s = _sellOrder("matrix", SALE_MIN);
        return abi.encodeCall(
            flashOption.sell, (s, _signSell(aliceKey, s), _sellTerms(Examples.priceAt(8), SALE_VALUATION, SALE_AMOUNT))
        );
    }

    /// @dev Alice's open bet, liquidated on its line.
    function _callLiquidate(address) private returns (bytes memory) {
        Position memory p = _bet(users.alice, "matrix", Side.Call);
        return abi.encodeCall(
            flashOption.liquidate, (Defaults.BTC, Defaults.LEVERAGE, p.liqPrice, p.startTime, _ids("matrix"))
        );
    }

    /// @dev Alice's bet at its expiry, settled at its 4x cap.
    function _callSettle(address) private returns (bytes memory) {
        Position memory p = _bet(users.alice, "matrix", Side.Call);
        vm.warp(_end(p));
        return abi.encodeCall(
            flashOption.settle, (Defaults.BTC, Defaults.LEVERAGE, Examples.priceAt(300), _end(p), _ids("matrix"))
        );
    }

    /// @dev Alice's bet, never ended, at its expiry plus the refund delay.
    function _callRefundExpired(address) private returns (bytes memory) {
        Position memory p = _bet(users.alice, "matrix", Side.Call);
        vm.warp(_end(p) + Defaults.REFUND_DELAY);
        return abi.encodeCall(flashOption.refundExpired, (_ids("matrix")));
    }

    /// @dev On a pool with $1 of free money, alice's winner at the 4x cap is owed most of its $40; a $100 top-up
    ///      lets the queue repay it.
    function _callRepay(address) private returns (bytes memory) {
        _useSmallPool(1e6);
        Position memory p = _bet(users.alice, "matrix", Side.Call);
        vm.warp(_end(p));
        _settle(Examples.priceAt(300), _end(p), _ids("matrix"));
        _fund(users.bob, 100e6);
        return abi.encodeCall(flashOption.repay, (1));
    }

    /// @dev $1 of the caller's own USDG, approved to the pool.
    function _callFund(address caller) private returns (bytes memory) {
        _mintUsdg(caller, 1e6);
        vm.prank(caller);
        usdg.approve(address(flashOption), 1e6);
        return abi.encodeCall(flashOption.fund, (1e6));
    }

    /// @dev Alice's winning payout, kept in `claimable` while USDG froze her, and her claim once unfrozen.
    function _callClaim(address) private returns (bytes memory) {
        Position memory p = _bet(users.alice, "matrix", Side.Call);
        vm.warp(_end(p));
        vm.prank(usdgAdmin);
        usdg.freeze(users.alice);
        _settle(Examples.priceAt(300), _end(p), _ids("matrix"));
        vm.prank(usdgAdmin);
        usdg.unfreeze(users.alice);
        return abi.encodeCall(flashOption.claim, (users.alice));
    }

    /// @dev A liquidation's loser fee, waiting to be swept.
    function _callSweepFees(address) private returns (bytes memory) {
        Position memory p = _bet(users.alice, "matrix", Side.Call);
        _liquidate(p.liqPrice, p.startTime, _ids("matrix"));
        return abi.encodeCall(flashOption.sweepFees, ());
    }

    /// @dev $1 of rewards, well inside the $1,000 above the floor.
    function _callWithdraw(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.withdraw, (WithdrawPurpose.Rewards, 1e6));
    }

    /// @dev A new feed's market, switched off.
    function _callCreateMarket(address) private view returns (bytes memory) {
        return abi.encodeCall(
            flashOption.createMarket, (ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, Defaults.marketConfig())
        );
    }

    /// @dev BTC's settings, unchanged.
    function _callSetConfig(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.setConfig, (Defaults.BTC, Defaults.LEVERAGE, _enabledConfig()));
    }

    /// @dev Pausing BTC.
    function _callPause(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.setPaused, (Defaults.BTC, Defaults.LEVERAGE, true));
    }

    /// @dev Unpausing BTC, which the guardian paused.
    function _callUnpause(address) private returns (bytes memory) {
        vm.prank(users.guardian);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, true);
        return abi.encodeCall(flashOption.setPaused, (Defaults.BTC, Defaults.LEVERAGE, false));
    }

    /// @dev Halting everything.
    function _callHalt(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.setHalted, (true));
    }

    /// @dev Unhalting, after the guardian halted.
    function _callUnhalt(address) private returns (bytes memory) {
        vm.prank(users.guardian);
        flashOption.setHalted(true);
        return abi.encodeCall(flashOption.setHalted, (false));
    }

    /// @dev Resetting the breaker.
    function _callResetBreaker(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.resetBreaker, ());
    }

    /// @dev Revoking the opener's key.
    function _callRevokeRelayer(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.revokeRelayer, (OPENER_ROLE, users.opener));
    }

    /// @dev A floor of $600.
    function _callSetPoolFloor(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.setPoolFloor, (600e6));
    }

    /// @dev Eve as both recipients.
    function _callSetRecipients(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.setRecipients, (users.eve, users.eve));
    }

    /// @dev A two-hour refund delay.
    function _callSetRefundDelay(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.setRefundDelay, (2 hours));
    }

    /// @dev A $2,000 limit over two hours.
    function _callSetBreaker(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.setBreaker, (2000e6, 2 hours));
    }

    /// @dev Making eve an opener.
    function _callGrantRole(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.grantRole, (OPENER_ROLE, users.eve));
    }

    /// @dev Taking the opener's role.
    function _callRevokeRole(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.revokeRole, (OPENER_ROLE, users.opener));
    }

    /// @dev The opener giving up its own role.
    function _callRenounceRole(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.renounceRole, (OPENER_ROLE, users.opener));
    }

    /// @dev Offering the admin role to bob.
    function _callBeginAdminTransfer(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.beginDefaultAdminTransfer, (users.bob));
    }

    /// @dev Withdrawing the admin's offer to bob.
    function _callCancelAdminTransfer(address) private returns (bytes memory) {
        vm.prank(users.admin);
        flashOption.beginDefaultAdminTransfer(users.bob);
        return abi.encodeCall(flashOption.cancelDefaultAdminTransfer, ());
    }

    /// @dev Accepting the admin's offer to bob, once its delay has passed.
    function _callAcceptAdminTransfer(address) private returns (bytes memory) {
        vm.prank(users.admin);
        flashOption.beginDefaultAdminTransfer(users.bob);
        vm.warp(block.timestamp + Defaults.ADMIN_TRANSFER_DELAY + 1);
        return abi.encodeCall(flashOption.acceptDefaultAdminTransfer, ());
    }

    /// @dev A one-day transfer delay.
    function _callChangeAdminDelay(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.changeDefaultAdminDelay, (1 days));
    }

    /// @dev Rolling back a delay change (none is pending, which is allowed).
    function _callRollbackAdminDelay(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.rollbackDefaultAdminDelay, ());
    }

    /// @dev The set-up again.
    function _callInitialize(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.initialize, (_defaultInitParams()));
    }

    /// @dev An upgrade to another copy of the contract.
    function _callUpgrade(address) private view returns (bytes memory) {
        return abi.encodeCall(flashOption.upgradeToAndCall, (address(nextImplementation), ""));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Builds `row`'s call for `caller` from a snapshot, sends it as `caller`, checks the outcome against the
    ///      gate, and goes back to the snapshot.
    function _checkCell(Row memory row, address caller) private {
        uint256 state = vm.snapshotState();
        bytes memory data = row.call(caller);
        vm.prank(caller);
        (bool ok, bytes memory returned) = address(flashOption).call(data);
        string memory cell = string.concat(row.name, ", called by ", vm.getLabel(caller));
        if (_lets(row.gate, caller)) {
            assertTrue(ok, string.concat(cell, ", was refused: ", vm.toString(returned)));
        } else {
            assertFalse(ok, string.concat(cell, ", went through"));
            assertEq(returned, _refusal(row.gate, caller), cell);
        }
        vm.revertToStateAndDelete(state);
    }

    /// @dev Skips an address that holds a role, is the opener (who may renounce the opener's role), or can't be
    ///      pranked.
    function _assumeNoPower(address caller) private view {
        assumeNotForgeAddress(caller);
        vm.assume(caller != address(0) && caller != users.opener);
        bytes32[6] memory roles = [ADMIN_ROLE, UPGRADER_ROLE, OPERATOR_ROLE, GUARDIAN_ROLE, OPENER_ROLE, SETTLER_ROLE];
        for (uint256 i; i < roles.length; ++i) {
            vm.assume(!flashOption.hasRole(roles[i], caller));
        }
    }

    /// @dev Whether a row names `name`.
    function _hasRow(Row[] memory rows, string memory name) private pure returns (bool) {
        for (uint256 i; i < rows.length; ++i) {
            if (keccak256(bytes(rows[i].name)) == keccak256(bytes(name))) return true;
        }
        return false;
    }

    /// @dev Whether `names` holds `name`.
    function _isIn(string[] memory names, string memory name) private pure returns (bool) {
        for (uint256 i; i < names.length; ++i) {
            if (keccak256(bytes(names[i])) == keccak256(bytes(name))) return true;
        }
        return false;
    }
}
