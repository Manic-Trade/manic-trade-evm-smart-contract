// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Test} from "forge-std/Test.sol";

import {BaseScript} from "../../script/Base.s.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";

/// @title BaseScriptHarness
/// @notice `BaseScript` with its inputs file and its token choice exposed.
contract BaseScriptHarness is BaseScript {
    string internal file;

    constructor(string memory file_) {
        file = file_;
    }

    function token(Inputs memory i, Record memory r) external view returns (address) {
        return _token(i, r);
    }

    function _chainsFile() internal view override returns (string memory) {
        return bytes(file).length == 0 ? CHAINS : file;
    }
}

/// @title Base_Script_Test
/// @notice What every script shares: the inputs it refuses, and which token it uses.
contract Base_Script_Test is Test {
    string internal constant BAD = "test/fixtures/scripts/chains-bad-enabled.toml";

    function test_RevertWhen_AnEnabledLeverageIsNotCreated() public {
        BaseScriptHarness harness = new BaseScriptHarness(BAD);
        vm.expectRevert(bytes("chains.toml: an enabled leverage is not in `leverages`"));
        harness.inputs();
    }

    function test_RevertWhen_AValueDoesNotFitItsType() public {
        vm.chainId(31_338);
        BaseScriptHarness harness = new BaseScriptHarness(BAD);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 48, 2 ** 48));
        harness.inputs();
    }

    function test_TheTokenIsChainsTomlsWhenItNamesOne() public {
        BaseScriptHarness harness = new BaseScriptHarness("");
        BaseScript.Inputs memory i = harness.inputs();
        address usdg = address(new MockUSDG("Global Dollar", "USDG", address(this)));
        address mock = address(new MockUSDG("Global Dollar", "USDG", address(this)));
        i.token = usdg;
        BaseScript.Record memory r;
        (r.token, r.tokenIsMock) = (mock, true);
        assertEq(harness.token(i, r), usdg, "chains.toml's token wins over the record's mock");
        i.token = address(0);
        assertEq(harness.token(i, r), mock, "with none named, the recorded mock");
    }

    function test_RevertWhen_ThereIsNoToken() public {
        BaseScriptHarness harness = new BaseScriptHarness("");
        BaseScript.Inputs memory i = harness.inputs();
        BaseScript.Record memory r;
        vm.expectRevert(bytes("no token: chains.toml's is zero and the record has no mock (run DeployMockUsdg)"));
        harness.token(i, r);
        i.token = makeAddr("no code");
        vm.expectRevert(bytes("the token has no code on this chain"));
        harness.token(i, r);
    }
}
