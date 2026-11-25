// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";
import {MockOddERC1271Wallet} from "../mocks/MockOddERC1271Wallet.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";
import {IUsdgSigningView, UsdgSigner} from "../utils/UsdgSigner.sol";
import {Fork_Base_Test} from "./ForkBase.t.sol";

/// @title MockUsdgVsReal_Fork_Test
/// @notice The mock against the real token (security checklist TOK-4). Every other test runs on `MockUSDG`, so they
///         prove something only if the mock behaves exactly as the real USDG does. Each test here takes the same steps
///         on both, from the same state, on a fork of Robinhood Chain mainnet, and requires each step to end the same:
///         going through or refused, with the same return or revert data, the same logs and the same balances. The
///         steps cover what the leverage contract relies on, and every behaviour the mock's notes say it copies:
///         - transfers, freezes and the pause;
///         - allowances, which are spent even at the maximum;
///         - permits, and cancelling them;
///         - the EIP-3009 pull the contract uses, with each of its checks and its silent no-op on a used or cancelled
///           nonce;
///         - signatures from ERC-1271 wallets and EIP-7702 accounts;
///         - the EIP-712 domain at each chain id, and the constants.
/// @dev The mock is deployed on the fork with the real token's freeze and pause role holder as its admin, so one
///      caller freezes and pauses both. Signatures are made per token: the two EIP-712 domains differ only in the
///      contract's address. Left out, as the mock's notes say: its admin-only extras (minting, wiping, changing the
///      admin) and Paxos's roles. Run each week (`.github/workflows/fork.yml`), the suite also catches the real
///      token changing under us.
contract MockUsdgVsReal_Fork_Test is Fork_Base_Test {
    /// @dev What one step did, as the tests compare it.
    struct Step {
        string what; // what the step does
        bool ok; // whether it went through
        bytes result; // its return or revert data
        bytes logs; // every log the token emitted: topics and data, in order
        bytes balances; // the watched accounts' balances after it
    }

    /// @dev keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)").
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    /// @dev The selectors of the functions taken by signature.
    string private constant PERMIT = "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)";
    string private constant PERMIT_BYTES = "permit(address,address,uint256,uint256,bytes)";
    string private constant RECEIVE = "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)";
    string private constant CANCEL = "cancelAuthorization(address,bytes32,bytes)";

    MockUSDG internal mock;
    MockERC1271Wallet internal wallet;
    address internal holder;
    uint256 internal holderKey;
    address internal receiver;
    address internal spender;
    /// @dev An account with an EIP-7702 delegation to code that refuses every ERC-1271 question.
    address internal delegated;
    uint256 internal delegatedKey;
    uint256 internal strangerKey;

    address[] private _watched;
    Step[] private _steps;

    function setUp() public override {
        super.setUp();
        mock = new MockUSDG("Global Dollar", "USDG", USDG_ROLES);
        (holder, holderKey) = makeAddrAndKey("holder");
        receiver = makeAddr("receiver");
        spender = makeAddr("spender");
        (delegated, delegatedKey) = makeAddrAndKey("delegated");
        (, strangerKey) = makeAddrAndKey("stranger");
        wallet = new MockERC1271Wallet(holder);
        address refusesAll = address(new MockOddERC1271Wallet(MockOddERC1271Wallet.Answer.Revert));
        vm.etch(delegated, abi.encodePacked(hex"ef0100", refusesAll));

        // The same starting balances on both tokens.
        address[5] memory watched = [holder, receiver, spender, address(wallet), delegated];
        for (uint256 i; i < watched.length; ++i) {
            _watched.push(watched[i]);
        }
        for (uint256 i; i < _watched.length; ++i) {
            deal(REAL_USDG, _watched[i], 100e6);
            deal(address(mock), _watched[i], 100e6);
        }
    }

    function test_TransfersEndTheSame() external {
        _onBoth(_transfers);
    }

    function test_FreezesEndTheSame() external {
        _onBoth(_freezes);
    }

    function test_ThePauseEndsTheSame() external {
        _onBoth(_pause);
    }

    function test_AllowancesEndTheSame() external {
        _onBoth(_allowances);
    }

    function test_PermitsEndTheSame() external {
        _onBoth(_permits);
    }

    function test_TheEip3009PullEndsTheSame() external {
        _onBoth(_pulls);
    }

    function test_WalletAndDelegatedAccountSignaturesEndTheSame() external {
        _onBoth(_walletSignatures);
    }

    function test_TheDomainAndTheConstantsAreTheSame() external {
        _onBoth(_domainAndConstants);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The scenarios, each run on the real token and on the mock
    // ---------------------------------------------------------------------------------------------------------------

    function _transfers(address token) private {
        _step("a transfer", token, holder, _transfer(receiver, 1e6));
        _step("a transfer of 0", token, holder, _transfer(receiver, 0));
        _step("a transfer to oneself", token, holder, _transfer(holder, 1e6));
        _step("a transfer of more than the balance", token, holder, _transfer(receiver, 1000e6));
        _step("a transfer to the zero address", token, holder, _transfer(address(0), 1e6));
    }

    function _freezes(address token) private {
        _step("freezing an account", token, USDG_ROLES, abi.encodeWithSignature("freeze(address)", holder));
        _step("freezing it again", token, USDG_ROLES, abi.encodeWithSignature("freeze(address)", holder));
        _note("it reads as frozen", token, abi.encode(MockUSDG(token).isFrozen(holder)));
        _step("its transfer", token, holder, _transfer(receiver, 1e6));
        _step("a transfer to it", token, receiver, _transfer(holder, 1e6));
        _step("its approval", token, holder, abi.encodeCall(IERC20.approve, (spender, 1e6)));
        _step("unfreezing it", token, USDG_ROLES, abi.encodeWithSignature("unfreeze(address)", holder));
        _step("unfreezing it again", token, USDG_ROLES, abi.encodeWithSignature("unfreeze(address)", holder));
        _step("its transfer once unfrozen", token, holder, _transfer(receiver, 1e6));
    }

    function _pause(address token) private {
        _step("pausing", token, USDG_ROLES, abi.encodeWithSignature("pause()"));
        _step("pausing again", token, USDG_ROLES, abi.encodeWithSignature("pause()"));
        _note("it reads as paused", token, abi.encode(MockUSDG(token).paused()));
        _step("a transfer while paused", token, holder, _transfer(receiver, 1e6));
        _step("an approval while paused", token, holder, abi.encodeCall(IERC20.approve, (spender, 1e6)));
        _step("unpausing", token, USDG_ROLES, abi.encodeWithSignature("unpause()"));
        _step("unpausing again", token, USDG_ROLES, abi.encodeWithSignature("unpause()"));
        _step("a transfer once resumed", token, holder, _transfer(receiver, 1e6));
    }

    function _allowances(address token) private {
        _step("approving the most", token, holder, abi.encodeCall(IERC20.approve, (spender, type(uint256).max)));
        _step("a transferFrom", token, spender, abi.encodeCall(IERC20.transferFrom, (holder, receiver, 1e6)));
        _note("the most, less what was spent", token, abi.encode(IERC20(token).allowance(holder, spender)));
        _step("approving 1", token, holder, abi.encodeCall(IERC20.approve, (spender, 1)));
        _step(
            "a transferFrom beyond the allowance",
            token,
            spender,
            abi.encodeCall(IERC20.transferFrom, (holder, receiver, 2))
        );
        _step("an approval of the zero address", token, holder, abi.encodeCall(IERC20.approve, (address(0), 1)));
        _step(
            "raising an allowance by 0",
            token,
            holder,
            abi.encodeWithSignature("increaseApproval(address,uint256)", spender, 0)
        );
        _step(
            "raising it by 5", token, holder, abi.encodeWithSignature("increaseApproval(address,uint256)", spender, 5)
        );
        _step(
            "lowering it by 2", token, holder, abi.encodeWithSignature("decreaseApproval(address,uint256)", spender, 2)
        );
        _step(
            "lowering it by more than it is",
            token,
            holder,
            abi.encodeWithSignature("decreaseApproval(address,uint256)", spender, 100)
        );
        _step("freezing the spender", token, USDG_ROLES, abi.encodeWithSignature("freeze(address)", spender));
        _step(
            "a frozen spender's transferFrom",
            token,
            spender,
            abi.encodeCall(IERC20.transferFrom, (holder, receiver, 1))
        );
    }

    function _permits(address token) private {
        uint256 deadline = block.timestamp + 1 hours;
        _step("a permit", token, receiver, _permit(token, holderKey, holder, 5e6, deadline));
        _note("the nonce after", token, abi.encode(IUsdgSigningView(token).nonces(holder)));
        _step("a permit signed by someone else", token, receiver, _permit(token, strangerKey, holder, 5e6, deadline));
        _step("an expired permit", token, receiver, _permit(token, holderKey, holder, 5e6, block.timestamp - 1));
        bytes memory signature =
            UsdgSigner.sign(holderKey, UsdgSigner.permitDigest(token, holder, spender, 6e6, deadline));
        _step(
            "a permit as one signature",
            token,
            receiver,
            abi.encodeWithSignature(PERMIT_BYTES, holder, spender, 6e6, deadline, signature)
        );
        _step(
            "the same signature again",
            token,
            receiver,
            abi.encodeWithSignature(PERMIT_BYTES, holder, spender, 6e6, deadline, signature)
        );
        _step("skipping 3 permit nonces", token, holder, abi.encodeWithSignature("cancelPermits(uint256)", 3));
        _step("skipping more than 100", token, holder, abi.encodeWithSignature("cancelPermits(uint256)", 101));
        _step("pausing", token, USDG_ROLES, abi.encodeWithSignature("pause()"));
        _step("a permit while paused", token, receiver, _permit(token, holderKey, holder, 5e6, deadline));
    }

    function _pulls(address token) private {
        UsdgSigner.Authorization memory a = _authorization(holder, receiver, 3e6, "the first");
        bytes memory pull = _pull(token, holderKey, a);
        _step("a pull by someone else than the payee", token, spender, pull);
        _step("a pull by the payee", token, receiver, pull);
        _note("the nonce reads as used", token, abi.encode(MockUSDG(token).authorizationState(holder, a.nonce)));
        _step("the same pull again (a used nonce)", token, receiver, pull);

        UsdgSigner.Authorization memory early = _authorization(holder, receiver, 1e6, "too early");
        early.validAfter = block.timestamp + 10;
        _step("a pull before it is valid", token, receiver, _pull(token, holderKey, early));
        UsdgSigner.Authorization memory late = _authorization(holder, receiver, 1e6, "too late");
        late.validBefore = block.timestamp - 1;
        _step("a pull after it expired", token, receiver, _pull(token, holderKey, late));
        UsdgSigner.Authorization memory other = _authorization(holder, receiver, 1e6, "someone else's");
        _step("a pull signed by someone else", token, receiver, _pull(token, strangerKey, other));
        UsdgSigner.Authorization memory big = _authorization(holder, receiver, 1000e6, "too big");
        _step("a pull of more than the balance", token, receiver, _pull(token, holderKey, big));

        UsdgSigner.Authorization memory cancelled = _authorization(holder, receiver, 1e6, "cancelled");
        bytes memory cancel = UsdgSigner.sign(holderKey, UsdgSigner.cancelDigest(token, holder, cancelled.nonce));
        _step(
            "cancelling an authorization",
            token,
            spender,
            abi.encodeWithSignature(CANCEL, holder, cancelled.nonce, cancel)
        );
        _step("cancelling it again", token, spender, abi.encodeWithSignature(CANCEL, holder, cancelled.nonce, cancel));
        _step("a pull with the cancelled nonce", token, receiver, _pull(token, holderKey, cancelled));

        UsdgSigner.Authorization memory frozen = _authorization(holder, receiver, 1e6, "frozen");
        _step("freezing the payer", token, USDG_ROLES, abi.encodeWithSignature("freeze(address)", holder));
        _step("a pull from a frozen payer", token, receiver, _pull(token, holderKey, frozen));
        _step("unfreezing the payer", token, USDG_ROLES, abi.encodeWithSignature("unfreeze(address)", holder));
        _step("pausing", token, USDG_ROLES, abi.encodeWithSignature("pause()"));
        _step("a pull while paused", token, receiver, _pull(token, holderKey, frozen));
    }

    function _walletSignatures(address token) private {
        UsdgSigner.Authorization memory a = _authorization(address(wallet), receiver, 2e6, "the wallet's");
        _step("a wallet's pull, signed by its owner", token, receiver, _pull(token, holderKey, a));
        UsdgSigner.Authorization memory b = _authorization(address(wallet), receiver, 2e6, "a stranger's");
        _step("a wallet's pull, signed by a stranger", token, receiver, _pull(token, strangerKey, b));
        wallet.setRejectAll(true);
        UsdgSigner.Authorization memory c = _authorization(address(wallet), receiver, 2e6, "refused");
        _step("a pull from a wallet that refuses", token, receiver, _pull(token, holderKey, c));

        UsdgSigner.Authorization memory d = _authorization(delegated, receiver, 2e6, "the delegated account's");
        _step("a delegated account's pull, signed with its own key", token, receiver, _pull(token, delegatedKey, d));
        UsdgSigner.Authorization memory e = _authorization(delegated, receiver, 2e6, "not its key");
        _step("a delegated account's pull, signed with another key", token, receiver, _pull(token, strangerKey, e));
    }

    function _domainAndConstants(address token) private {
        _note("the domain at 4663", token, abi.encode(_domainSeparator(token) == _expectedDomain(token)));
        vm.chainId(1);
        _note("the domain at chain id 1", token, abi.encode(_domainSeparator(token) == _expectedDomain(token)));
        vm.chainId(ROBINHOOD_CHAIN_ID);
        string[10] memory views = [
            "decimals()",
            "name()",
            "symbol()",
            "PERMIT_TYPEHASH()",
            "TRANSFER_WITH_AUTHORIZATION_TYPEHASH()",
            "RECEIVE_WITH_AUTHORIZATION_TYPEHASH()",
            "CANCEL_AUTHORIZATION_TYPEHASH()",
            "EIP712_VERSION_PREFIX()",
            "MAX_NONCE_INCREMENT()",
            "paused()"
        ];
        for (uint256 i; i < views.length; ++i) {
            _step(views[i], token, holder, abi.encodeWithSignature(views[i]));
        }
        // Neither has EIP-5267's `eip712Domain()`: both refuse it, the real token's router with `FacetNotFound()`
        // and the mock with no data. Only that both refuse it is compared.
        (bool hasEip5267,) = token.staticcall(abi.encodeWithSignature("eip712Domain()"));
        _note("no eip712Domain()", token, abi.encode(hasEip5267));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Running a scenario on both tokens
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Runs `scenario` on the real token, then on the mock from the same state, and requires every step to end
    ///      the same on both.
    function _onBoth(function(address) internal scenario) private {
        uint256 start = vm.snapshotState();
        scenario(REAL_USDG);
        Step[] memory real = _steps;
        vm.revertToState(start);
        scenario(address(mock));
        Step[] memory mocked = _steps;
        assertGt(real.length, 0, "the scenario took steps");
        assertEq(mocked.length, real.length, "the same steps on both");
        for (uint256 i; i < real.length; ++i) {
            string memory what = real[i].what;
            assertEq(mocked[i].ok, real[i].ok, string.concat(what, ": goes through on both, or on neither"));
            assertEq(mocked[i].result, real[i].result, string.concat(what, ": the same return or revert data"));
            assertEq(mocked[i].logs, real[i].logs, string.concat(what, ": the same logs"));
            assertEq(mocked[i].balances, real[i].balances, string.concat(what, ": the same balances"));
        }
    }

    /// @dev Has `caller` call `token` with `data`, and records how it ended.
    function _step(string memory what, address token, address caller, bytes memory data) private {
        vm.recordLogs();
        vm.prank(caller);
        (bool ok, bytes memory result) = token.call(data);
        _record(what, token, ok, result);
    }

    /// @dev Records `value`, read from `token`, as a step that went through and returned it.
    function _note(string memory what, address token, bytes memory value) private {
        vm.recordLogs();
        _record(what, token, true, value);
    }

    /// @dev Records a step: how it ended, the token's logs since the step began, and the watched balances.
    function _record(string memory what, address token, bool ok, bytes memory result) private {
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bytes memory tokenLogs;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == token) {
                tokenLogs = bytes.concat(tokenLogs, abi.encode(logs[i].topics, logs[i].data));
            }
        }
        bytes memory balances;
        for (uint256 i; i < _watched.length; ++i) {
            balances = bytes.concat(balances, abi.encode(IERC20(token).balanceOf(_watched[i])));
        }
        _steps.push(Step({what: what, ok: ok, result: result, logs: tokenLogs, balances: balances}));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Calls and signatures
    // ---------------------------------------------------------------------------------------------------------------

    function _transfer(address to, uint256 value) private pure returns (bytes memory) {
        return abi.encodeCall(IERC20.transfer, (to, value));
    }

    /// @dev A permit of `value` from `owner` to `spender`, signed with `key`, in its v, r, s form.
    function _permit(
        address token,
        uint256 key,
        address owner,
        uint256 value,
        uint256 deadline
    )
        private
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) =
            UsdgSigner.signVrs(key, UsdgSigner.permitDigest(token, owner, spender, value, deadline));
        return abi.encodeWithSignature(PERMIT, owner, spender, value, deadline, v, r, s);
    }

    /// @dev An authorization for `to` to pull `value` from `from`, valid from a second ago for an hour, with a nonce
    ///      named by `label`.
    function _authorization(
        address from,
        address to,
        uint256 value,
        string memory label
    )
        private
        view
        returns (UsdgSigner.Authorization memory)
    {
        return UsdgSigner.Authorization({
            from: from,
            to: to,
            value: value,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256(bytes(label))
        });
    }

    /// @dev The EIP-3009 pull of `a`, signed with `key`, in the bytes-signature form the contract uses.
    function _pull(address token, uint256 key, UsdgSigner.Authorization memory a) private view returns (bytes memory) {
        bytes memory signature = UsdgSigner.sign(key, UsdgSigner.authorizationDigest(token, a, true));
        return abi.encodeWithSignature(RECEIVE, a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, signature);
    }

    function _domainSeparator(address token) private view returns (bytes32) {
        return IUsdgSigningView(token).DOMAIN_SEPARATOR();
    }

    /// @dev The EIP-712 domain the mock's notes say both use: "Global Dollar", version "1", this chain, the token.
    function _expectedDomain(address token) private view returns (bytes32) {
        return
            keccak256(
                abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("Global Dollar"), keccak256("1"), block.chainid, token)
            );
    }
}
