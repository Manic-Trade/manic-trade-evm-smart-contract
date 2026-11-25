// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ManicFlashOption} from "../../src/ManicFlashOption.sol";
import {OpenOrder, SellOrder} from "../../src/types/OrderTypes.sol";
import {Base_Test} from "../Base.t.sol";
import {ManicFlashOptionHarness} from "../harnesses/ManicFlashOptionHarness.sol";
import {OrderSigner} from "../utils/OrderSigner.sol";

/// @title Eip712Vectors_Differential_Test
/// @notice Replays test/fixtures/eip712_vectors.json, the EIP-712 vectors shared with the backend
///         (docs/ARCHITECTURE.md §7, security checklist SIG-2). The contract's domain, and every order's digest and
///         signature, must be exactly what the vectors say.
/// @dev The vectors were made by Foundry's `cast` (alloy's EIP-712), not by this repo's Solidity
///      (test/fixtures/eip712_vectors.py). They use a fixed domain, so the harness is deployed behind a proxy at the
///      vectors' address, on the vectors' chain. The struct hashes are checked without a proxy in
///      test/unit/OrderLib.t.sol.
contract Eip712Vectors_Differential_Test is Base_Test {
    string internal constant OPEN_ORDER_TYPE = "OpenOrder(bytes32 positionId,address user,bytes32 marketId,"
        "uint16 leverage,uint8 side,uint64 stake,uint16 durationSecs,uint48 notBefore,uint48 deadline)";
    string internal constant SELL_ORDER_TYPE =
        "SellOrder(bytes32 positionId,uint64 minAmount,uint48 notBefore,uint48 deadline)";

    string internal json;
    /// @dev The harness behind a proxy at the vectors' `verifyingContract`, on the vectors' chain.
    ManicFlashOptionHarness internal fixedProxy;
    uint256 internal signerKey;
    address internal signer;

    function setUp() public override {
        super.setUp();
        json = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/eip712_vectors.json"));
        signerKey = uint256(vm.parseJsonBytes32(json, ".signer.key"));
        signer = vm.parseJsonAddress(json, ".signer.address");
        vm.chainId(vm.parseJsonUint(json, ".domain.chainId"));
        address where = vm.parseJsonAddress(json, ".domain.verifyingContract");
        bytes memory initialize = abi.encodeCall(ManicFlashOption.initialize, (_defaultInitParams()));
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy", abi.encode(address(new ManicFlashOptionHarness()), initialize), where
        );
        fixedProxy = ManicFlashOptionHarness(where);
    }

    function test_TheDomainIsTheVectors() external view {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            fixedProxy.eip712Domain();
        assertEq(name, vm.parseJsonString(json, ".domain.name"), "name");
        assertEq(version, vm.parseJsonString(json, ".domain.version"), "version");
        assertEq(chainId, vm.parseJsonUint(json, ".domain.chainId"), "chain id");
        assertEq(verifyingContract, vm.parseJsonAddress(json, ".domain.verifyingContract"), "verifying contract");
        bytes32 typeHash =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        assertEq(vm.parseJsonBytes32(json, ".domainTypeHash"), typeHash, "the domain's type hash");
        bytes32 separator = keccak256(
            abi.encode(typeHash, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract)
        );
        assertEq(separator, vm.parseJsonBytes32(json, ".domainSeparator"), "the domain separator");
        assertEq(vm.addr(signerKey), signer, "the vectors' key signs as their signer");
    }

    function test_EveryOpenOrderVectorReproduces() external view {
        uint256 i;
        for (; vm.keyExistsJson(json, _at(".openOrders", i)); ++i) {
            string memory path = _at(".openOrders", i);
            OpenOrder memory o =
                abi.decode(vm.parseJsonType(json, string.concat(path, ".order"), OPEN_ORDER_TYPE), (OpenOrder));
            assertEq(o.user, signer, "the vectors' orders are the signer's own");
            bytes32 digest = vm.parseJsonBytes32(json, string.concat(path, ".digest"));
            _assertDigestOf(vm.parseJsonBytes32(json, string.concat(path, ".structHash")), digest);
            assertEq(fixedProxy.hashOpenOrder(o), digest, string.concat(path, ": the contract's digest"));
            _assertSignature(digest, vm.parseJsonBytes(json, string.concat(path, ".signature")), path);
        }
        assertEq(i, 4, "every open vector");
    }

    function test_EverySellOrderVectorReproduces() external view {
        uint256 i;
        for (; vm.keyExistsJson(json, _at(".sellOrders", i)); ++i) {
            string memory path = _at(".sellOrders", i);
            SellOrder memory s =
                abi.decode(vm.parseJsonType(json, string.concat(path, ".order"), SELL_ORDER_TYPE), (SellOrder));
            bytes32 digest = vm.parseJsonBytes32(json, string.concat(path, ".digest"));
            _assertDigestOf(vm.parseJsonBytes32(json, string.concat(path, ".structHash")), digest);
            assertEq(fixedProxy.hashSellOrder(s), digest, string.concat(path, ": the contract's digest"));
            _assertSignature(digest, vm.parseJsonBytes(json, string.concat(path, ".signature")), path);
        }
        assertEq(i, 2, "every sell vector");
    }

    /// @dev The vector's digest is EIP-712's `keccak256(0x1901 ‖ domainSeparator ‖ structHash)` of its struct hash.
    function _assertDigestOf(bytes32 structHash, bytes32 digest) private view {
        bytes32 separator = vm.parseJsonBytes32(json, ".domainSeparator");
        assertEq(keccak256(abi.encodePacked(hex"1901", separator, structHash)), digest, "digest = 0x1901 || ds || sh");
    }

    /// @dev Foundry signs the digest with the vectors' key to the same bytes (RFC 6979), and the contract accepts it.
    function _assertSignature(bytes32 digest, bytes memory signature, string memory path) private view {
        assertEq(OrderSigner.sign(signerKey, digest), signature, string.concat(path, ": the same signature"));
        fixedProxy.exposed_checkSignature(signer, digest, signature);
    }

    /// @dev The JSON path of vector `i` in `list`.
    function _at(string memory list, uint256 i) private pure returns (string memory) {
        return string.concat(list, "[", vm.toString(i), "]");
    }
}
