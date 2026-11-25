// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ManicFlashOption} from "../../../src/ManicFlashOption.sol";
import {OpenOrder, SellOrder} from "../../../src/types/OrderTypes.sol";
import {Side} from "../../../src/types/StorageTypes.sol";
import {Base_Test} from "../../Base.t.sol";
import {Defaults} from "../../utils/Defaults.sol";

/// @title Views_Concrete_Test
/// @notice The read-only functions beside the getters: `version`, the role ids and the EIP-712 hash helpers
///         (docs/ARCHITECTURE.md §7, §8.9). The getters are tested in getters.t.sol.
/// @dev The hash helpers are checked against the shared vectors in test/signing/Eip712Vectors.t.sol. Here they
///      are checked against EIP-712's definition, on this test's own deployment, and for their binding to it.
contract Views_Concrete_Test is Base_Test {
    function test_VersionIsTheFirstRelease() external view {
        assertEq(flashOption.version(), Defaults.VERSION);
    }

    /// @dev The ids the backend and the scripts use with `hasRole`: keccak256 of each name, as OpenZeppelin does.
    function test_EachRoleIdIsTheHashOfItsName() external view {
        assertEq(flashOption.DEFAULT_ADMIN_ROLE(), bytes32(0), "DEFAULT_ADMIN_ROLE");
        assertEq(flashOption.UPGRADER_ROLE(), keccak256("UPGRADER_ROLE"), "UPGRADER_ROLE");
        assertEq(flashOption.OPERATOR_ROLE(), keccak256("OPERATOR_ROLE"), "OPERATOR_ROLE");
        assertEq(flashOption.GUARDIAN_ROLE(), keccak256("GUARDIAN_ROLE"), "GUARDIAN_ROLE");
        assertEq(flashOption.OPENER_ROLE(), keccak256("OPENER_ROLE"), "OPENER_ROLE");
        assertEq(flashOption.SETTLER_ROLE(), keccak256("SETTLER_ROLE"), "SETTLER_ROLE");
    }

    /// @dev EIP-712: `keccak256(0x1901 || domainSeparator || hashStruct(order))`, each part rebuilt here from the
    ///      type strings and the contract's `eip712Domain()`.
    function test_TheHashHelpersReturnTheEip712DigestOfTheOrder() external view {
        bytes32 separator = _separator(flashOption);
        OpenOrder memory o = _openOrder();
        bytes32 openStruct = keccak256(
            abi.encode(
                keccak256(
                    "OpenOrder(bytes32 positionId,address user,bytes32 marketId,uint16 leverage,uint8 side,"
                    "uint64 stake,uint16 durationSecs,uint48 notBefore,uint48 deadline)"
                ),
                o.positionId,
                o.user,
                o.marketId,
                o.leverage,
                uint8(o.side),
                o.stake,
                o.durationSecs,
                o.notBefore,
                o.deadline
            )
        );
        assertEq(flashOption.hashOpenOrder(o), keccak256(abi.encodePacked(hex"1901", separator, openStruct)), "open");

        SellOrder memory s = _sellOrder();
        bytes32 sellStruct = keccak256(
            abi.encode(
                keccak256("SellOrder(bytes32 positionId,uint64 minAmount,uint48 notBefore,uint48 deadline)"),
                s.positionId,
                s.minAmount,
                s.notBefore,
                s.deadline
            )
        );
        assertEq(flashOption.hashSellOrder(s), keccak256(abi.encodePacked(hex"1901", separator, sellStruct)), "sell");
    }

    /// @dev The same order gets another digest on another deployment and on another chain, so a signature can't be
    ///      replayed there (security checklist SIG-1).
    function test_TheHashHelpersBindAnOrderToThisContractAndThisChain() external {
        OpenOrder memory o = _openOrder();
        SellOrder memory s = _sellOrder();
        bytes32 openHere = flashOption.hashOpenOrder(o);
        bytes32 sellHere = flashOption.hashSellOrder(s);

        ManicFlashOption other = ManicFlashOption(_deployProxy(_defaultInitParams()));
        assertNotEq(other.hashOpenOrder(o), openHere, "open: another deployment");
        assertNotEq(other.hashSellOrder(s), sellHere, "sell: another deployment");

        vm.chainId(4663); // Robinhood Chain's mainnet
        assertNotEq(flashOption.hashOpenOrder(o), openHere, "open: another chain");
        assertNotEq(flashOption.hashSellOrder(s), sellHere, "sell: another chain");
    }

    /// @dev The domain separator, rebuilt from what `eip712Domain()` reports (ERC-5267).
    function _separator(ManicFlashOption target) private view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            target.eip712Domain();
        assertEq(name, Defaults.EIP712_NAME, "name");
        assertEq(version, Defaults.EIP712_VERSION, "version");
        assertEq(chainId, block.chainid, "chain id");
        assertEq(verifyingContract, address(target), "the proxy, not the implementation");
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function _openOrder() private view returns (OpenOrder memory) {
        return OpenOrder({
            positionId: keccak256("alice's position"),
            user: users.alice,
            marketId: Defaults.BTC,
            leverage: Defaults.LEVERAGE,
            side: Side.Put,
            stake: 25e6,
            durationSecs: 60,
            notBefore: uint48(block.timestamp),
            deadline: uint48(block.timestamp + 30)
        });
    }

    function _sellOrder() private view returns (SellOrder memory) {
        return SellOrder({
            positionId: keccak256("alice's position"),
            minAmount: 12e6,
            notBefore: uint48(block.timestamp),
            deadline: uint48(block.timestamp + 30)
        });
    }
}
