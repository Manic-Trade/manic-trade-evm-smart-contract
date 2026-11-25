// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Breaker, Market, PoolState, Position} from "../types/StorageTypes.sol";

/// @title FlashOptionStorage
/// @author Manic
/// @notice The contract's only storage: one ERC-7201 namespaced struct, `Layout`, at a fixed slot that can't collide
///         with the OpenZeppelin bases, which keep their state in namespaces of their own.
/// @dev This must stay an abstract contract in the inheritance chain, not a library or a file-level struct. The
///      OpenZeppelin upgrades plugin only finds namespaced structs declared in a contract it inherits, and otherwise
///      skips the layout check without any error (docs/ARCHITECTURE.md §4.2). Every field below, and every field of
///      the structs it embeds, is append-only (§5). test/unit/FlashOptionStorage.t.sol pins each one's slot and byte
///      offset.
/// @custom:security-contact See SECURITY.md
abstract contract FlashOptionStorage {
    /// @notice The root of the contract's storage: settings, the pool's books, the circuit breaker, then the
    ///         markets, positions, the repay queue and the claimable balances.
    /// @dev 14 slots: 9 of values and 5 mapping roots. New fields go at the end only, because `pool` and `breaker`
    ///      are embedded structs that can't grow.
    /// @custom:storage-location erc7201:manic.storage.FlashOption
    struct Layout {
        // slot 0 (30 bytes)
        IERC20 token; // the stablecoin (USDG), set once in initialize
        uint8 tokenDecimals; // read once in initialize; 6 to 9, so every amount fits a uint64
        bool halted; // the global stop, set by the guardian or the operator
        uint16 marketCount; // the number of markets created, and so the next market's index
        uint48 refundDelaySecs; // the safety refund delay after expiry (24 hours by default; 0 = off)
        // slot 1
        address feeRecipient; // receives swept fees and seed recovery
        // slot 2
        address rewardsRecipient; // receives rewards withdrawals
        // slots 3-6
        PoolState pool; // the books
        // slots 7-8
        Breaker breaker; // the payout circuit breaker
        // slots 9-13: mapping roots, one slot each
        mapping(uint16 index => Market market) markets; // index 0 to marketCount - 1
        mapping(bytes32 marketKey => uint16 indexPlusOne) marketIndexPlusOne; // keccak256(feed, leverage); 0 = unknown
        mapping(bytes32 positionId => Position position) positions; // a used id is never removed
        mapping(uint64 seq => bytes32 positionId) iouQueue; // the repay queue, read from nextRepaySeq
        mapping(address account => uint64 amount) claimable; // payouts whose transfer failed, waiting for claim
        // new fields go below this line only
    }

    /// @dev The namespace's slot: keccak256(abi.encode(uint256(keccak256("manic.storage.FlashOption")) - 1)) &
    ///      ~bytes32(uint256(0xff)), as `cast index-erc7201 manic.storage.FlashOption` prints it. The `- 1` means
    ///      no known string hashes to the slot; clearing the last byte starts the namespace on a 256-slot boundary,
    ///      which ERC-7201 does in anticipation of Verkle trees grouping storage in runs of 256 slots.
    ///      FlashOptionStorage.t.sol recomputes it.
    bytes32 private constant _FLASH_OPTION_STORAGE_LOCATION =
        0xf273be9a24eeab036a40c6c3509d6aa7cccb8da2ecbd9965c4f2a996a54c2200;

    /// @notice Returns the contract's storage root.
    /// @dev Every function reads and writes storage through this pointer, as `Layout storage $ =
    ///      _getFlashOptionStorage();`, the same idiom as OpenZeppelin 5. The assembly only sets the pointer's slot:
    ///      it reads and writes nothing.
    /// @return root The `Layout` at the namespace's slot.
    function _getFlashOptionStorage() internal pure returns (Layout storage root) {
        // forge-lint: disable-next-item(inline-assembly)
        // slither-disable-start assembly
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            root.slot := _FLASH_OPTION_STORAGE_LOCATION
        }
        // slither-disable-end assembly
    }
}
