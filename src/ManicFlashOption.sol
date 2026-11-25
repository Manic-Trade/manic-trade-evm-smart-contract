// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IManicFlashOption} from "./interfaces/IManicFlashOption.sol";
import {IManicFlashOptionAdmin} from "./interfaces/IManicFlashOptionAdmin.sol";
import {IManicFlashOptionViews} from "./interfaces/IManicFlashOptionViews.sol";
import {AdminModule} from "./modules/AdminModule.sol";
import {PoolModule} from "./modules/PoolModule.sol";
import {SettlementModule} from "./modules/SettlementModule.sol";
import {TradingModule} from "./modules/TradingModule.sol";
import {ViewsModule} from "./modules/ViewsModule.sol";
import {InitParams} from "./types/ParamTypes.sol";

/// @title ManicFlashOption
/// @author Manic
/// @notice The Manic Flash Option: short-lived bets on a price at high leverage (1000x, 500x or 100x), all paid from
///         one pool. This is the implementation that sits behind an ERC-1967 proxy (UUPS).
/// @dev The entry contract only (docs/CONVENTIONS.md §1): the parent list, the constructor, `initialize`,
///      `_authorizeUpgrade` and `version`. The behaviour lives in the modules (`AdminModule`, `TradingModule`,
///      `SettlementModule`, `PoolModule` and `ViewsModule`) and in `FlashOptionBase`,
///      which every module inherits. The interface comes first in the parent list: see docs/ARCHITECTURE.md §3.2.
///      There are no state variables and no immutables: all state is in the ERC-7201 `Layout`
///      (src/base/FlashOptionStorage.sol).
/// @custom:security-contact See SECURITY.md
contract ManicFlashOption is IManicFlashOption, AdminModule, TradingModule, SettlementModule, PoolModule, ViewsModule {
    /// @notice This implementation's version, returned by `version()`.
    string private constant _VERSION = "1.0.0";

    /// @notice The EIP-712 domain's name and version, which the users' order signatures commit to (§7).
    string private constant _EIP712_NAME = "Manic Flash Option";
    string private constant _EIP712_VERSION = "1";

    /// @notice The accepted range of token decimals. With at most 9, the largest amounts still fit a `uint64`; USDG
    ///         and USDC have 6.
    uint8 private constant _MIN_TOKEN_DECIMALS = 6;
    uint8 private constant _MAX_TOKEN_DECIMALS = 9;

    /// @notice Locks the implementation itself, so that nobody can initialize it and act as its admin. Only the
    ///         proxy is ever initialized.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IManicFlashOptionAdmin
    /// @dev The checks run first, in the documented order: the addresses, then the token's decimals (read here, once).
    ///      The floor, refund-delay and breaker checks run inside their setters, in that order. The whole call reverts
    ///      on any failure, so a half-set proxy can't exist.
    function initialize(InitParams calldata p) external override initializer {
        _checkAddresses(p);
        uint8 decimals = IERC20Metadata(address(p.token)).decimals();
        if (decimals < _MIN_TOKEN_DECIMALS || decimals > _MAX_TOKEN_DECIMALS) revert InvalidTokenDecimals(decimals);

        // The OpenZeppelin bases: one default admin with its two-step transfer delay, and the signing domain.
        __AccessControlDefaultAdminRules_init(p.adminTransferDelay, p.admin);
        __EIP712_init(_EIP712_NAME, _EIP712_VERSION);
        _grantRoles(p);

        Layout storage $ = _getFlashOptionStorage();
        $.token = p.token;
        $.tokenDecimals = decimals;
        _setPoolFloor(p.poolFloor);
        _setRecipients(p.feeRecipient, p.rewardsRecipient);
        _setRefundDelay(p.refundDelaySecs);
        _setBreaker(p.breakerMaxNetProfit, p.breakerWindowSecs);
    }

    /// @inheritdoc IManicFlashOptionViews
    function version() external pure override returns (string memory) {
        return _VERSION;
    }

    /// @notice The only gate on upgrades: the caller must hold `UPGRADER_ROLE` (the 48-hour timelock on mainnet).
    /// @dev OpenZeppelin's `upgradeToAndCall` calls this first, then checks that the new implementation is UUPS too
    ///      (`proxiableUUID`), so the proxy can never be left without an upgrade function.
    function _authorizeUpgrade(address) internal view override onlyRole(UPGRADER_ROLE) {}

    /// @notice Grants every role but the default admin's, which `__AccessControlDefaultAdminRules_init` granted.
    /// @param p The setup parameters.
    function _grantRoles(InitParams calldata p) private {
        _grantRole(UPGRADER_ROLE, p.upgrader);
        _grantRole(OPERATOR_ROLE, p.operator);
        _grantRole(GUARDIAN_ROLE, p.guardian);
        for (uint256 i; i < p.openers.length; ++i) {
            _grantRole(OPENER_ROLE, p.openers[i]);
        }
        for (uint256 i; i < p.settlers.length; ++i) {
            _grantRole(SETTLER_ROLE, p.settlers[i]);
        }
    }

    /// @notice Reverts `ZeroAddress` if any address in the setup is unset, checked in field order.
    /// @param p The setup parameters.
    function _checkAddresses(InitParams calldata p) private pure {
        if (p.admin == address(0) || p.upgrader == address(0)) revert ZeroAddress();
        if (p.operator == address(0) || p.guardian == address(0)) revert ZeroAddress();
        // Rejecting the whole setup over one unset relayer address is the point, so a revert inside these loops is
        // intended (forge-lint's require-revert-in-loop is excluded in foundry.toml, which says why).
        for (uint256 i; i < p.openers.length; ++i) {
            if (p.openers[i] == address(0)) revert ZeroAddress();
        }
        for (uint256 i; i < p.settlers.length; ++i) {
            if (p.settlers[i] == address(0)) revert ZeroAddress();
        }
        if (address(p.token) == address(0)) revert ZeroAddress();
        if (p.feeRecipient == address(0) || p.rewardsRecipient == address(0)) revert ZeroAddress();
    }
}
