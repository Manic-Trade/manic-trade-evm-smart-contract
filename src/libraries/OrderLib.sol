// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {OpenOrder, SellOrder} from "../types/OrderTypes.sol";

/// @title OrderLib
/// @author Manic
/// @notice The EIP-712 type hashes and struct hashes of the two orders a user signs: `OpenOrder` and `SellOrder`
///         (docs/ARCHITECTURE.md §7).
/// @dev A struct hash is EIP-712's `hashStruct`: keccak256 of the type hash followed by each field, in the type
///      string's order, each encoded as 32 bytes (`side` as a `uint8`). The contract turns it into the digest the user
///      signed with `_hashTypedDataV4`, which adds the domain: the name, the version, the chain id and the proxy's
///      address. The backend hashes the same structs, so test/fixtures/eip712_vectors.json pins every type hash and
///      struct hash, computed by an independent EIP-712 implementation.
/// @custom:security-contact See SECURITY.md
library OrderLib {
    /// @notice keccak256 of the `OpenOrder` type string.
    bytes32 internal constant OPEN_ORDER_TYPEHASH = keccak256(
        "OpenOrder(bytes32 positionId,address user,bytes32 marketId,uint16 leverage,uint8 side,uint64 stake,"
        "uint16 durationSecs,uint48 notBefore,uint48 deadline)"
    );

    /// @notice keccak256 of the `SellOrder` type string.
    bytes32 internal constant SELL_ORDER_TYPEHASH =
        keccak256("SellOrder(bytes32 positionId,uint64 minAmount,uint48 notBefore,uint48 deadline)");

    /// @notice The EIP-712 struct hash of an order to open a position.
    /// @param o The order.
    /// @return The struct hash.
    function hashStruct(OpenOrder calldata o) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                OPEN_ORDER_TYPEHASH,
                o.positionId,
                o.user,
                o.marketId,
                o.leverage,
                o.side,
                o.stake,
                o.durationSecs,
                o.notBefore,
                o.deadline
            )
        );
    }

    /// @notice The EIP-712 struct hash of an order to sell a position early.
    /// @param s The order.
    /// @return The struct hash.
    function hashStruct(SellOrder calldata s) internal pure returns (bytes32) {
        return keccak256(abi.encode(SELL_ORDER_TYPEHASH, s.positionId, s.minAmount, s.notBefore, s.deadline));
    }
}
