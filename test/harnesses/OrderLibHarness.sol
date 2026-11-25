// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {OrderLib} from "../../src/libraries/OrderLib.sol";
import {OpenOrder, SellOrder} from "../../src/types/OrderTypes.sol";

/// @title OrderLibHarness
/// @notice Exposes `OrderLib`'s internal functions as external calls, so the unit tests can call them with calldata.
contract OrderLibHarness {
    function hashOpenOrderStruct(OpenOrder calldata o) external pure returns (bytes32) {
        return OrderLib.hashStruct(o);
    }

    function hashSellOrderStruct(SellOrder calldata s) external pure returns (bytes32) {
        return OrderLib.hashStruct(s);
    }
}
