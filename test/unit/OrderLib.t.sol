// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {OrderLib} from "../../src/libraries/OrderLib.sol";
import {OpenOrder, SellOrder} from "../../src/types/OrderTypes.sol";
import {OrderLibHarness} from "../harnesses/OrderLibHarness.sol";

/// @title OrderLib_Unit_Test
/// @notice `OrderLib` without a proxy: each type hash is the hash of the type string the backend uses
///         (docs/ARCHITECTURE.md §7), and each struct hash in test/fixtures/eip712_vectors.json comes out of
///         `hashStruct` exactly.
/// @dev The vectors were made by Foundry's `cast` (alloy's EIP-712), so a dropped, swapped or retyped field shows
///      up here as a different hash. Orders are read with `vm.parseJsonType` and an explicit type string, which keeps
///      the struct's field order (docs/CONVENTIONS.md §9).
contract OrderLib_Unit_Test is Test {
    string internal constant OPEN_ORDER_TYPE = "OpenOrder(bytes32 positionId,address user,bytes32 marketId,"
        "uint16 leverage,uint8 side,uint64 stake,uint16 durationSecs,uint48 notBefore,uint48 deadline)";
    string internal constant SELL_ORDER_TYPE =
        "SellOrder(bytes32 positionId,uint64 minAmount,uint48 notBefore,uint48 deadline)";

    OrderLibHarness internal lib;
    string internal json;

    function setUp() public {
        lib = new OrderLibHarness();
        json = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/eip712_vectors.json"));
    }

    function test_EachTypeHashIsTheHashOfItsTypeString() external view {
        assertEq(OrderLib.OPEN_ORDER_TYPEHASH, keccak256(bytes(OPEN_ORDER_TYPE)), "OpenOrder");
        assertEq(OrderLib.SELL_ORDER_TYPEHASH, keccak256(bytes(SELL_ORDER_TYPE)), "SellOrder");
        // The same strings and hashes as the shared vectors.
        assertEq(vm.parseJsonString(json, ".openOrderType"), OPEN_ORDER_TYPE, "OpenOrder's string");
        assertEq(vm.parseJsonString(json, ".sellOrderType"), SELL_ORDER_TYPE, "SellOrder's string");
        assertEq(vm.parseJsonBytes32(json, ".openOrderTypeHash"), OrderLib.OPEN_ORDER_TYPEHASH, "OpenOrder's hash");
        assertEq(vm.parseJsonBytes32(json, ".sellOrderTypeHash"), OrderLib.SELL_ORDER_TYPEHASH, "SellOrder's hash");
    }

    function test_EveryOpenOrderStructHashIsTheVectors() external view {
        uint256 i;
        for (; vm.keyExistsJson(json, _at(".openOrders", i)); ++i) {
            bytes memory encoded =
                vm.parseJsonType(json, string.concat(_at(".openOrders", i), ".order"), OPEN_ORDER_TYPE);
            bytes32 expected = vm.parseJsonBytes32(json, string.concat(_at(".openOrders", i), ".structHash"));
            assertEq(lib.hashOpenOrderStruct(abi.decode(encoded, (OpenOrder))), expected, _at(".openOrders", i));
        }
        assertEq(i, 4, "every open vector");
    }

    function test_EverySellOrderStructHashIsTheVectors() external view {
        uint256 i;
        for (; vm.keyExistsJson(json, _at(".sellOrders", i)); ++i) {
            bytes memory encoded =
                vm.parseJsonType(json, string.concat(_at(".sellOrders", i), ".order"), SELL_ORDER_TYPE);
            bytes32 expected = vm.parseJsonBytes32(json, string.concat(_at(".sellOrders", i), ".structHash"));
            assertEq(lib.hashSellOrderStruct(abi.decode(encoded, (SellOrder))), expected, _at(".sellOrders", i));
        }
        assertEq(i, 2, "every sell vector");
    }

    /// @dev The JSON path of vector `i` in `list`.
    function _at(string memory list, uint256 i) private pure returns (string memory) {
        return string.concat(list, "[", vm.toString(i), "]");
    }
}
