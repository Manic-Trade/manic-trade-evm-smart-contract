// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ManicFlashOption} from "../../../src/ManicFlashOption.sol";
import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {InitParams} from "../../../src/types/ParamTypes.sol";
import {Base_Test} from "../../Base.t.sol";
import {MockDecimalsToken} from "../../mocks/MockDecimalsToken.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title SetPoolFloor_Concrete_Test
/// @notice Every branch of `setPoolFloor`, from test/concrete/setPoolFloor/setPoolFloor.tree: the floor must be at
///         least 500 whole tokens at the token's decimals, checked at 6 and at 9 decimals.
/// @dev The floor shares `_setPoolFloor` with `initialize`. 500 whole tokens at 17 decimals (500 × 10^17) wouldn't
///      fit the `uint64` floor, but can't arise, because `initialize` only accepts 6 to 9 decimals.
contract SetPoolFloor_Concrete_Test is Base_Test {
    function test_RevertWhen_TheCallerIsNotTheAdmin() external {
        // it should revert: every user but the admin, with a floor that is too low as well
        address[] memory callers = _everyoneBut(users.admin, users.admin);
        bytes32 adminRole = flashOption.DEFAULT_ADMIN_ROLE();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], adminRole)
            );
            vm.prank(callers[i]);
            flashOption.setPoolFloor(0);
        }
    }

    modifier whenTheCallerIsTheAdmin() {
        vm.startPrank(users.admin);
        _;
        vm.stopPrank();
    }

    function test_RevertWhen_TheFloorIsBelow500WholeTokens() external whenTheCallerIsTheAdmin {
        // it should revert: at 6 decimals, a unit below 500 tokens, and zero...
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.setPoolFloor(499_999_999);
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.setPoolFloor(0);

        // ...and at 9 decimals, where the 6-decimal floor is too little
        ManicFlashOption nine = _nineDecimalProxy();
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        nine.setPoolFloor(500_000_000);
    }

    function test_WhenTheFloorIsAtLeast500WholeTokens() external whenTheCallerIsTheAdmin {
        uint256 slot4 = LayoutReader.word(address(flashOption), 4);
        uint256 others = slot4 & ~uint256(type(uint64).max);

        // it should emit {PoolFloorUpdated}
        vm.expectEmit(address(flashOption));
        emit Events.PoolFloorUpdated(type(uint64).max);
        flashOption.setPoolFloor(type(uint64).max); // a higher floor is a policy choice

        // it should store the floor, and nothing else in its slot
        assertEq(LayoutReader.pool(address(flashOption)).poolFloor, type(uint64).max, "the highest floor");
        assertEq(LayoutReader.word(address(flashOption), 4) & ~uint256(type(uint64).max), others, "rest of slot 4");
        flashOption.setPoolFloor(500_000_000);
        assertEq(LayoutReader.pool(address(flashOption)).poolFloor, 500_000_000, "exactly 500 tokens at 6 decimals");

        // 500 whole tokens at 9 decimals is 500_000_000_000
        ManicFlashOption nine = _nineDecimalProxy();
        nine.setPoolFloor(500_000_000_000);
        assertEq(LayoutReader.pool(address(nine)).poolFloor, 500_000_000_000, "exactly 500 tokens at 9 decimals");
    }

    /// @dev A proxy over a 9-decimal token, set up with its lowest floor. The admin calls it (the modifier's prank).
    function _nineDecimalProxy() private returns (ManicFlashOption) {
        vm.stopPrank();
        InitParams memory p = _defaultInitParams();
        p.token = IERC20(address(new MockDecimalsToken(9)));
        p.poolFloor = 500_000_000_000;
        ManicFlashOption proxy = ManicFlashOption(_deployProxy(p));
        vm.startPrank(users.admin);
        return proxy;
    }
}
