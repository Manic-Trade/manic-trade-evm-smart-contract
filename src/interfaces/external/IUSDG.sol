// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

/// @title IUSDG
/// @author Manic
/// @notice The one USDG function the contract calls beyond ERC-20: EIP-3009's `receiveWithAuthorization`, in the form
///         that takes the signature as bytes, so a contract wallet's (ERC-1271) authorisation works too.
/// @dev Paxos's USDG on Robinhood Chain is built from facets. This form's selector, `0x88b7ab63`, is registered to its
///      EIP-3009 facet (checked live on mainnet 4663, 2026-11-11). Only the payee, `to`, may submit it, so nobody can
///      front-run the contract's pull. A nonce that was already used or cancelled is a silent no-op: no revert and no
///      transfer. That is why `open` checks its own balance afterwards (docs/ARCHITECTURE.md §8.2).
/// @custom:security-contact See SECURITY.md
interface IUSDG {
    /// @notice Moves `value` from `from` to the caller, with `from`'s signed authorisation.
    /// @param from The authorising holder.
    /// @param to The payee, which must be the caller.
    /// @param value The amount, in base units.
    /// @param validAfter The authorisation is valid only after this time.
    /// @param validBefore The authorisation is valid only before this time.
    /// @param nonce A unique id: the contract uses the position id, so each authorisation funds one position, once.
    /// @param signature `from`'s signature of the authorisation (EIP-712), or a contract wallet's.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    )
        external;
}
