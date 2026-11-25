// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";

import {IManicFlashOptionAdmin} from "./IManicFlashOptionAdmin.sol";
import {IManicFlashOptionErrors} from "./IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents} from "./IManicFlashOptionEvents.sol";
import {IManicFlashOptionPool} from "./IManicFlashOptionPool.sol";
import {IManicFlashOptionRoles} from "./IManicFlashOptionRoles.sol";
import {IManicFlashOptionSettlement} from "./IManicFlashOptionSettlement.sol";
import {IManicFlashOptionTrading} from "./IManicFlashOptionTrading.sol";
import {IManicFlashOptionViews} from "./IManicFlashOptionViews.sol";

/// @title IManicFlashOption
/// @author Manic
/// @notice The contract's ABI, the one the backend and the frontend build against. It is committed as
///         `abi/IManicFlashOption.json`, and CI fails if that file is out of date.
/// @dev An aggregate: it declares nothing itself (docs/CONVENTIONS.md §6). It holds our function slices, one per
///      module, every event, every error and the role ids, plus OpenZeppelin's role management
///      (`IAccessControlDefaultAdminRules`) and EIP-712 domain (`IERC5267`) interfaces. The upgrade functions
///      (`upgradeToAndCall`, `proxiableUUID`) are only in the implementation's own ABI, because only deploy and
///      upgrade scripts call them.
///
///      The order of the parents matters (docs/ARCHITECTURE.md §3.2). Our interfaces come first (the slices, then the
///      events, errors and roles), then OpenZeppelin's. `ManicFlashOption`, `FlashOptionBase` and every module list
///      them in that same order. Otherwise the compiler can't linearize the inheritance graph.
/// @custom:security-contact See SECURITY.md
interface IManicFlashOption is
    IManicFlashOptionAdmin,
    IManicFlashOptionTrading,
    IManicFlashOptionSettlement,
    IManicFlashOptionPool,
    IManicFlashOptionViews,
    IManicFlashOptionEvents,
    IManicFlashOptionErrors,
    IManicFlashOptionRoles,
    IAccessControlDefaultAdminRules,
    IERC5267
{}
