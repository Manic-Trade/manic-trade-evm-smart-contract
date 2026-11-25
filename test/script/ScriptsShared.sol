// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {BaseScript} from "../../script/Base.s.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {ManicFlashOption} from "../../src/ManicFlashOption.sol";
import {InitParams} from "../../src/types/ParamTypes.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";

/// @title Scripts_Shared
/// @notice A proxy deployed by `Deploy.deploy` with chains.toml's anvil inputs, except that `holder` (a script under
///         test) holds the admin, upgrader, operator and guardian roles and the mock token's admin, so the script's
///         own calls are the role holder's without a broadcast.
abstract contract Scripts_Shared is Test {
    /// @dev OpenZeppelin 5's `Initializable` storage, by the ERC-7201 formula.
    bytes32 internal constant INITIALIZABLE_SLOT =
        keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff));

    Deploy internal deployer;
    MockUSDG internal token;
    ManicFlashOption internal proxy;
    address internal implementation;

    function _deployFor(address holder) internal returns (BaseScript.Inputs memory i) {
        deployer = Deploy(vm.deployCode("Deploy.s.sol:Deploy"));
        i = deployer.inputs();
        (i.deployer, i.admin, i.upgrader, i.operator, i.guardian) = (holder, holder, holder, holder, holder);
        token = new MockUSDG("Global Dollar", "USDG", holder);
        ManicFlashOption deployed;
        (deployed, proxy) = deployer.deploy(_params(i));
        implementation = address(deployed);
    }

    function _params(BaseScript.Inputs memory i) internal view returns (InitParams memory p) {
        p = InitParams({
            admin: i.admin,
            adminTransferDelay: i.adminTransferDelay,
            upgrader: i.upgrader,
            operator: i.operator,
            guardian: i.guardian,
            openers: i.openers,
            settlers: i.settlers,
            token: IERC20(address(token)),
            poolFloor: i.poolFloor,
            feeRecipient: i.feeRecipient,
            rewardsRecipient: i.rewardsRecipient,
            refundDelaySecs: i.refundDelaySecs,
            breakerMaxNetProfit: i.breakerMaxNetProfit,
            breakerWindowSecs: i.breakerWindowSecs
        });
    }
}
