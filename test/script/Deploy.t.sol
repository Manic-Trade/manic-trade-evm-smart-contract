// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseScript} from "../../script/Base.s.sol";
import {MarketSettings} from "../../script/config/MarketSettings.sol";
import {ManicFlashOption} from "../../src/ManicFlashOption.sol";
import {InitParams} from "../../src/types/ParamTypes.sol";
import {Scripts_Shared} from "./ScriptsShared.sol";

/// @title Deploy_Script_Test
/// @notice `Deploy.check` passes on a deployment that matches its setup, and names each value that doesn't.
contract Deploy_Script_Test is Scripts_Shared {
    BaseScript.Inputs internal inputs;
    address internal holder;

    function setUp() public {
        holder = makeAddr("holder");
        inputs = _deployFor(holder);
    }

    function test_TheCheckPassesOnTheDeployment() public view {
        deployer.check(proxy, implementation, _params(inputs), holder);
    }

    function test_RevertWhen_ASettingDiffers() public {
        InitParams memory p = _params(inputs);
        address other = makeAddr("other");

        p.admin = other;
        _expectCheckFails(p, "Deploy check: admin");
        p = _params(inputs);
        p.adminTransferDelay += 1;
        _expectCheckFails(p, "Deploy check: the admin transfer delay");
        p = _params(inputs);
        p.upgrader = other;
        _expectCheckFails(p, "Deploy check: upgrader");
        p = _params(inputs);
        p.operator = other;
        _expectCheckFails(p, "Deploy check: operator");
        p = _params(inputs);
        p.guardian = other;
        _expectCheckFails(p, "Deploy check: guardian");
        p = _params(inputs);
        p.openers[1] = other;
        _expectCheckFails(p, "Deploy check: an opener");
        p = _params(inputs);
        p.settlers[0] = other;
        _expectCheckFails(p, "Deploy check: a settler");
        p = _params(inputs);
        p.token = IERC20(other);
        _expectCheckFails(p, "Deploy check: token");
        p = _params(inputs);
        p.poolFloor += 1;
        _expectCheckFails(p, "Deploy check: the pool floor");
        p = _params(inputs);
        p.feeRecipient = other;
        _expectCheckFails(p, "Deploy check: the fee recipient");
        p = _params(inputs);
        p.rewardsRecipient = other;
        _expectCheckFails(p, "Deploy check: the rewards recipient");
        p = _params(inputs);
        p.refundDelaySecs += 1;
        _expectCheckFails(p, "Deploy check: the refund delay");
        p = _params(inputs);
        p.breakerMaxNetProfit += 1;
        _expectCheckFails(p, "Deploy check: the breaker's limit");
        p = _params(inputs);
        p.breakerWindowSecs += 1;
        _expectCheckFails(p, "Deploy check: the breaker's window");
    }

    function test_RevertWhen_TheProxyPointsElsewhere() public {
        vm.expectRevert(bytes("Deploy check: the proxy's implementation"));
        deployer.check(proxy, address(token), _params(inputs), holder);
    }

    function test_RevertWhen_TheImplementationIsNotLocked() public {
        vm.store(implementation, INITIALIZABLE_SLOT, bytes32(0));
        _expectCheckFails(_params(inputs), "Deploy check: the implementation is locked");
    }

    function test_RevertWhen_TheProxyIsNotInitializedOnce() public {
        vm.store(address(proxy), INITIALIZABLE_SLOT, bytes32(uint256(2)));
        _expectCheckFails(_params(inputs), "Deploy check: the proxy is initialized once");
    }

    function test_RevertWhen_TheVersionOrDomainDiffers() public {
        vm.mockCall(address(proxy), abi.encodeCall(ManicFlashOption.version, ()), abi.encode("9.9.9"));
        _expectCheckFails(_params(inputs), "Deploy check: version");
        vm.clearMockedCalls();
        _mockDomain("Manic", "1", block.chainid, address(proxy));
        _expectCheckFails(_params(inputs), "Deploy check: the EIP-712 name, version");
        _mockDomain("Manic Flash Option", "2", block.chainid, address(proxy));
        _expectCheckFails(_params(inputs), "Deploy check: the EIP-712 name, version");
        _mockDomain("Manic Flash Option", "1", 1, address(proxy));
        _expectCheckFails(_params(inputs), "Deploy check: the EIP-712 domain");
        _mockDomain("Manic Flash Option", "1", block.chainid, implementation);
        _expectCheckFails(_params(inputs), "Deploy check: the EIP-712 domain");
    }

    function test_RevertWhen_TheDeployerHoldsARoleItWasNotGiven() public {
        bytes32 role = proxy.OPENER_ROLE();
        vm.prank(holder);
        proxy.grantRole(role, holder);
        _expectCheckFails(_params(inputs), "Deploy check: the deployer holds a role it was not given");
    }

    function test_RevertWhen_TheContractIsNotFresh() public {
        vm.prank(holder);
        proxy.setHalted(true);
        _expectCheckFails(_params(inputs), "Deploy check: not halted");
        vm.prank(holder);
        proxy.setHalted(false);

        vm.startPrank(holder);
        token.mint(holder, 1e6);
        token.approve(address(proxy), 1e6);
        proxy.fund(1e6);
        vm.stopPrank();
        _expectCheckFails(_params(inputs), "Deploy check: the pool is empty");
    }

    function test_RevertWhen_AMarketExists() public {
        vm.prank(holder);
        proxy.createMarket(MarketSettings.BTC, 1000, MarketSettings.BTC_PRICE_EXPONENT, MarketSettings.btc(1000));
        _expectCheckFails(_params(inputs), "Deploy check: no market yet");
    }

    function _expectCheckFails(InitParams memory p, string memory reason) private {
        vm.expectRevert(bytes(reason));
        deployer.check(proxy, implementation, p, holder);
    }

    /// @dev Makes the proxy's `eip712Domain()` report the given domain.
    function _mockDomain(string memory name, string memory version, uint256 chainId, address verifying) private {
        vm.mockCall(
            address(proxy),
            abi.encodeWithSignature("eip712Domain()"),
            abi.encode(bytes1(0x0f), name, version, chainId, verifying, bytes32(0), new uint256[](0))
        );
    }
}
