// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title MockUSDG
/// @author Manic
/// @notice A test double for Paxos USDG ("Global Dollar") as deployed on Robinhood Chain. Every contract test uses
///         it, and it is the test token on the Robinhood testnet, which has no USDG.
/// @dev Our contract trusts nothing about the token, so the tests only prove something if this mock fails exactly
///      the way the real token does. It copies, from Paxos's source (`paxosglobal/paxos-token-contracts` @ 674ac10)
///      and the live token at 0x5fc5360d0400a0fd4f2af552add042d716f1d168 (checked 2026-11-09):
///      - the error and event names and the order of the checks;
///      - EIP-712: version "1", `DOMAIN_SEPARATOR()` recomputed on every call, the standard EIP-2612 and EIP-3009
///        type hashes;
///      - freezing: a frozen sender or recipient blocks every transfer, and a frozen spender blocks `transferFrom`;
///      - pausing: transfers, approvals, permits and EIP-3009 calls revert with `ContractPaused`;
///      - allowances are always decremented (no "infinite allowance" shortcut);
///      - signatures are checked ECDSA first, then ERC-1271 (OpenZeppelin 4.9 order, which Paxos uses);
///      - an EIP-3009 nonce that was already used or cancelled is a silent no-op: `AuthorizationAlreadyUsed` is
///        emitted and nothing moves. The leverage contract must check its balance to notice.
///      Left out on purpose: Paxos's rewards accounting, batch functions, roles (one `admin` holds them all), and
///      the supply controller (`mint` is admin-only).
///      Checked against the live token each week: `test/fork/MockUsdgVsReal.t.sol` takes the same steps on
///      both and requires each to end the same, return or revert data, logs and balances alike. The live token sits
///      behind a facet router; the one difference it shows is `eip712Domain()`, which neither has and the router
///      refuses with `FacetNotFound()`.
contract MockUSDG {
    // ---------------------------------------------------------------------------------------------------------------
    // Constants: identical to the live token.
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Number of decimals: USDG has 6, so $1 is 1_000_000.
    uint8 public constant decimals = 6;

    /// @notice The two-byte prefix of every EIP-712 digest.
    bytes2 public constant EIP712_VERSION_PREFIX = hex"1901";

    /// @notice keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)").
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    /// @notice keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256
    ///         validBefore,bytes32 nonce)").
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;

    /// @notice keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256
    ///         validBefore,bytes32 nonce)").
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    /// @notice keccak256("CancelAuthorization(address authorizer,bytes32 nonce)").
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        0x158b0a9edf7a828aad02f63cd515c68ef2f50ba807396f6d12842833a1597429;

    /// @notice The most permit nonces `cancelPermits` can skip in one call.
    uint256 public constant MAX_NONCE_INCREMENT = 100;

    /// @dev keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)").
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    // ---------------------------------------------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Token name; also the EIP-712 domain name ("Global Dollar" on the real token).
    string public name;

    /// @notice Token symbol ("USDG" on the real token).
    string public symbol;

    /// @notice Holds every admin power: mint, pause, freeze, wipe (mock only; Paxos splits them across roles).
    address public admin;

    /// @notice Sum of all balances.
    uint256 public totalSupply;

    /// @notice True while every transfer, approval, permit and EIP-3009 call is blocked.
    bool public paused;

    /// @notice Token balances.
    mapping(address account => uint256 balance) public balanceOf;

    /// @notice Allowances: how much `spender` may move from `owner`.
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    /// @notice Frozen addresses can't send, receive, approve, be approved or spend allowances.
    mapping(address account => bool frozen) public isFrozen;

    /// @notice The next EIP-2612 permit nonce of each owner.
    mapping(address owner => uint256 nonce) public nonces;

    /// @notice Whether an EIP-3009 nonce of `authorizer` has been used or cancelled.
    mapping(address authorizer => mapping(bytes32 nonce => bool used)) public authorizationState;

    // ---------------------------------------------------------------------------------------------------------------
    // Events (names and fields as on the real token, plus `AdminChanged`)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice ERC-20 transfer, also emitted for mints (from 0) and wipes (to 0).
    event Transfer(address indexed from, address indexed to, uint256 value);
    /// @notice ERC-20 approval, also emitted by `permit`.
    event Approval(address indexed owner, address indexed spender, uint256 value);
    /// @notice The token was paused.
    event Pause();
    /// @notice The token was unpaused.
    event Unpause();
    /// @notice `addr` was frozen.
    event FreezeAddress(address indexed addr);
    /// @notice `addr` was unfrozen.
    event UnfreezeAddress(address indexed addr);
    /// @notice The balance of the frozen `addr` was destroyed.
    event FrozenAddressWiped(address indexed addr);
    /// @notice `value` tokens were minted to `to`.
    event SupplyIncreased(address indexed to, uint256 value);
    /// @notice `value` tokens were destroyed from `from`.
    event SupplyDecreased(address indexed from, uint256 value);
    /// @notice An EIP-3009 authorization was executed.
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    /// @notice An EIP-3009 authorization was cancelled before use.
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);
    /// @notice An EIP-3009 call reused a nonce. Nothing happened, and the call did not revert.
    event AuthorizationAlreadyUsed(address indexed authorizer, bytes32 indexed nonce);
    /// @notice `owner` skipped permit nonces up to `newNonce`.
    event PermitInvalidated(address indexed owner, uint256 newNonce);
    /// @notice Mock only: the admin changed.
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);

    // ---------------------------------------------------------------------------------------------------------------
    // Errors (names as on the real token, plus `NotAdmin`)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice An address argument was the zero address.
    error ZeroAddress();
    /// @notice The token is paused.
    error ContractPaused();
    /// @notice `pause` was called while already paused.
    error AlreadyPaused();
    /// @notice `unpause` was called while not paused.
    error AlreadyUnPaused();
    /// @notice A party to the call is frozen.
    error AddressFrozen();
    /// @notice `wipeFrozenAddress` was called on an address that is not frozen.
    error AddressNotFrozen();
    /// @notice The signature does not belong to the expected signer.
    error InvalidSignature();
    /// @notice The sender's balance is too low.
    error InsufficientFunds();
    /// @notice The spender's allowance is too low.
    error InsufficientAllowance();
    /// @notice `increaseApproval` / `decreaseApproval` were called with 0.
    error ZeroValue();
    /// @notice The permit's deadline has passed.
    error PermitExpired();
    /// @notice `cancelPermits` was called with 0 or more than `MAX_NONCE_INCREMENT`.
    error InvalidNonceCount();
    /// @notice `receiveWithAuthorization` was called by someone other than the payee.
    error CallerMustBePayee();
    /// @notice The authorization is not valid yet (`block.timestamp <= validAfter`).
    error AuthorizationInvalid();
    /// @notice The authorization has expired (`block.timestamp >= validBefore`).
    error AuthorizationExpired();
    /// @notice Mock only: the caller is not the admin.
    error NotAdmin();

    // ---------------------------------------------------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------------------------------------------------

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------------------------

    /// @param name_ Token and EIP-712 domain name. Tests use "Global Dollar" so digests match the real token's shape.
    /// @param symbol_ Token symbol.
    /// @param admin_ The account that may mint, pause, freeze and wipe.
    constructor(string memory name_, string memory symbol_, address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        admin = admin_;
        emit AdminChanged(address(0), admin_);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Mock only: hands every admin power to `newAdmin`.
    /// @param newAdmin The new admin; must not be the zero address.
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Creates `value` tokens for `to` (the real token routes this through its supply controller).
    /// @param to The recipient; must not be zero or frozen.
    /// @param value The amount, in base units.
    function mint(address to, uint256 value) external onlyAdmin {
        if (to == address(0)) revert ZeroAddress();
        if (isFrozen[to]) revert AddressFrozen();
        totalSupply += value;
        balanceOf[to] += value;
        emit SupplyIncreased(to, value);
        emit Transfer(address(0), to, value);
    }

    /// @notice Blocks every transfer, approval, permit and EIP-3009 call.
    function pause() external onlyAdmin {
        if (paused) revert AlreadyPaused();
        paused = true;
        emit Pause();
    }

    /// @notice Lifts the pause.
    function unpause() external onlyAdmin {
        if (!paused) revert AlreadyUnPaused();
        paused = false;
        emit Unpause();
    }

    /// @notice Freezes `addr`. Freezing an already frozen address is allowed, as on the real token.
    /// @param addr The address to freeze.
    function freeze(address addr) external onlyAdmin {
        isFrozen[addr] = true;
        emit FreezeAddress(addr);
    }

    /// @notice Unfreezes `addr`.
    /// @param addr The address to unfreeze.
    function unfreeze(address addr) external onlyAdmin {
        isFrozen[addr] = false;
        emit UnfreezeAddress(addr);
    }

    /// @notice Destroys the whole balance of the frozen `addr`.
    /// @param addr A frozen address.
    function wipeFrozenAddress(address addr) external onlyAdmin {
        if (!isFrozen[addr]) revert AddressNotFrozen();
        uint256 balance = balanceOf[addr];
        balanceOf[addr] = 0;
        totalSupply -= balance;
        emit FrozenAddressWiped(addr);
        emit SupplyDecreased(addr, balance);
        emit Transfer(addr, address(0), balance);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ERC-20
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Moves `value` tokens from the caller to `to`.
    /// @param to The recipient.
    /// @param value The amount.
    /// @return Always true; failures revert.
    function transfer(address to, uint256 value) external whenNotPaused returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @notice Moves `value` tokens from `from` to `to` using the caller's allowance.
    /// @dev The allowance is always decremented, even when it is `type(uint256).max`, as on the real token.
    /// @param from The owner.
    /// @param to The recipient.
    /// @param value The amount.
    /// @return Always true; failures revert.
    function transferFrom(address from, address to, uint256 value) external whenNotPaused returns (bool) {
        if (isFrozen[msg.sender]) revert AddressFrozen();
        if (value > allowance[from][msg.sender]) revert InsufficientAllowance();
        _transfer(from, to, value);
        allowance[from][msg.sender] -= value;
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to `value`.
    /// @param spender The spender; must not be zero.
    /// @param value The new allowance.
    /// @return Always true; failures revert.
    function approve(address spender, uint256 value) external whenNotPaused returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        if (isFrozen[spender] || isFrozen[msg.sender]) revert AddressFrozen();
        _approve(msg.sender, spender, value);
        return true;
    }

    /// @notice Raises the caller's allowance for `spender` by `addedValue`.
    /// @param spender The spender.
    /// @param addedValue The increase; must not be 0.
    /// @return Always true; failures revert.
    function increaseApproval(address spender, uint256 addedValue) external whenNotPaused returns (bool) {
        if (isFrozen[spender] || isFrozen[msg.sender]) revert AddressFrozen();
        if (addedValue == 0) revert ZeroValue();
        _approve(msg.sender, spender, allowance[msg.sender][spender] + addedValue);
        return true;
    }

    /// @notice Lowers the caller's allowance for `spender` by `subtractedValue`, stopping at 0.
    /// @param spender The spender.
    /// @param subtractedValue The decrease; must not be 0.
    /// @return Always true; failures revert.
    function decreaseApproval(address spender, uint256 subtractedValue) external whenNotPaused returns (bool) {
        if (isFrozen[spender] || isFrozen[msg.sender]) revert AddressFrozen();
        if (subtractedValue == 0) revert ZeroValue();
        uint256 current = allowance[msg.sender][spender];
        _approve(msg.sender, spender, subtractedValue > current ? 0 : current - subtractedValue);
        return true;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // EIP-712 and EIP-2612 (permit)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The EIP-712 domain separator: name, version "1", this chain and this contract.
    /// @dev Recomputed on every call, as on the real token, so it follows a chain fork.
    /// @return The domain separator.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256("1"), block.chainid, address(this))
        );
    }

    /// @notice Sets `owner`'s allowance for `spender` from a signature (v, r, s form).
    /// @param owner The token owner who signed.
    /// @param spender The spender.
    /// @param value The allowance.
    /// @param deadline The last timestamp the permit is valid at.
    /// @param v Signature v.
    /// @param r Signature r.
    /// @param s Signature s.
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
    {
        _permit(owner, spender, value, deadline, abi.encodePacked(r, s, v));
    }

    /// @notice Sets `owner`'s allowance for `spender` from a signature (bytes form; also accepts ERC-1271 wallets).
    /// @param owner The token owner who signed.
    /// @param spender The spender.
    /// @param value The allowance.
    /// @param deadline The last timestamp the permit is valid at.
    /// @param signature The signature.
    function permit(address owner, address spender, uint256 value, uint256 deadline, bytes memory signature) external {
        _permit(owner, spender, value, deadline, signature);
    }

    /// @notice Invalidates the caller's next `count` permit nonces.
    /// @param count How many nonces to skip, 1 to `MAX_NONCE_INCREMENT`.
    function cancelPermits(uint256 count) external {
        if (paused) revert ContractPaused();
        if (isFrozen[msg.sender]) revert AddressFrozen();
        if (count == 0 || count > MAX_NONCE_INCREMENT) revert InvalidNonceCount();
        nonces[msg.sender] += count;
        emit PermitInvalidated(msg.sender, nonces[msg.sender]);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // EIP-3009 (transfer with authorization)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Executes a signed transfer; anyone may submit it (v, r, s form).
    /// @param from The payer who signed.
    /// @param to The payee.
    /// @param value The amount.
    /// @param validAfter The authorization is valid only after this timestamp.
    /// @param validBefore The authorization is valid only before this timestamp.
    /// @param nonce A unique 32-byte nonce chosen by the payer.
    /// @param v Signature v.
    /// @param r Signature r.
    /// @param s Signature s.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        whenNotPaused
    {
        _transferWithAuthorization({
            typeHash: TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
            from: from,
            to: to,
            value: value,
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: abi.encodePacked(r, s, v)
        });
    }

    /// @notice Executes a signed transfer; anyone may submit it (bytes form).
    /// @param from The payer who signed.
    /// @param to The payee.
    /// @param value The amount.
    /// @param validAfter The authorization is valid only after this timestamp.
    /// @param validBefore The authorization is valid only before this timestamp.
    /// @param nonce A unique 32-byte nonce chosen by the payer.
    /// @param signature The signature.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    )
        external
        whenNotPaused
    {
        _transferWithAuthorization({
            typeHash: TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
            from: from,
            to: to,
            value: value,
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: signature
        });
    }

    /// @notice Executes a signed transfer that only the payee may submit, so nobody can front-run it (v, r, s form).
    /// @param from The payer who signed.
    /// @param to The payee; must be the caller.
    /// @param value The amount.
    /// @param validAfter The authorization is valid only after this timestamp.
    /// @param validBefore The authorization is valid only before this timestamp.
    /// @param nonce A unique 32-byte nonce chosen by the payer.
    /// @param v Signature v.
    /// @param r Signature r.
    /// @param s Signature s.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        whenNotPaused
    {
        if (to != msg.sender) revert CallerMustBePayee();
        _transferWithAuthorization({
            typeHash: RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
            from: from,
            to: to,
            value: value,
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: abi.encodePacked(r, s, v)
        });
    }

    /// @notice Executes a signed transfer that only the payee may submit, so nobody can front-run it (bytes form).
    /// @dev This is the call the leverage contract makes to pull a stake (docs/adr/0002-eip3009-stake-pull.md).
    /// @param from The payer who signed.
    /// @param to The payee; must be the caller.
    /// @param value The amount.
    /// @param validAfter The authorization is valid only after this timestamp.
    /// @param validBefore The authorization is valid only before this timestamp.
    /// @param nonce A unique 32-byte nonce chosen by the payer.
    /// @param signature The signature.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    )
        external
        whenNotPaused
    {
        if (to != msg.sender) revert CallerMustBePayee();
        _transferWithAuthorization({
            typeHash: RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
            from: from,
            to: to,
            value: value,
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: signature
        });
    }

    /// @notice Cancels an unused authorization (v, r, s form).
    /// @param authorizer The payer who signed the cancellation.
    /// @param nonce The nonce to cancel.
    /// @param v Signature v.
    /// @param r Signature r.
    /// @param s Signature s.
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        _cancelAuthorization(authorizer, nonce, abi.encodePacked(r, s, v));
    }

    /// @notice Cancels an unused authorization (bytes form).
    /// @param authorizer The payer who signed the cancellation.
    /// @param nonce The nonce to cancel.
    /// @param signature The signature.
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) external {
        _cancelAuthorization(authorizer, nonce, signature);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The real token's transfer rules, in its order: zero recipient, then frozen parties, then a zero-value
    ///      shortcut, then the balance check, then a self-transfer shortcut.
    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        if (isFrozen[to] || isFrozen[from]) revert AddressFrozen();
        if (value == 0) {
            emit Transfer(from, to, value);
            return;
        }
        if (value > balanceOf[from]) revert InsufficientFunds();
        if (from == to) {
            emit Transfer(from, to, value);
            return;
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value) internal {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _permit(address owner, address spender, uint256 value, uint256 deadline, bytes memory signature) internal {
        if (paused) revert ContractPaused();
        if (owner == address(0) || spender == address(0)) revert ZeroAddress();
        if (deadline < block.timestamp) revert PermitExpired();
        if (isFrozen[spender] || isFrozen[owner]) revert AddressFrozen();
        bytes32 digest =
            _digest(keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline)));
        if (!_isValidSignatureNow(owner, digest, signature)) revert InvalidSignature();
        _approve(owner, spender, value);
    }

    /// @dev A used or cancelled nonce returns early **without reverting**, as on the real token.
    function _transferWithAuthorization(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    )
        internal
    {
        if (block.timestamp <= validAfter) revert AuthorizationInvalid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (authorizationState[from][nonce]) {
            emit AuthorizationAlreadyUsed(from, nonce);
            return;
        }
        bytes32 digest = _digest(keccak256(abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce)));
        if (!_isValidSignatureNow(from, digest, signature)) revert InvalidSignature();
        authorizationState[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }

    /// @dev Cancelling a nonce that was already used or cancelled returns early without reverting.
    function _cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) internal {
        if (paused) revert ContractPaused();
        if (isFrozen[authorizer]) revert AddressFrozen();
        if (authorizationState[authorizer][nonce]) {
            emit AuthorizationAlreadyUsed(authorizer, nonce);
            return;
        }
        bytes32 digest = _digest(keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)));
        if (!_isValidSignatureNow(authorizer, digest, signature)) revert InvalidSignature();
        authorizationState[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(EIP712_VERSION_PREFIX, DOMAIN_SEPARATOR(), structHash));
    }

    /// @dev OpenZeppelin 4.9's order, which Paxos builds on: accept a valid ECDSA signature from `signer` first, and
    ///      only otherwise ask `signer` through ERC-1271. OpenZeppelin 5.x does the reverse for any address with
    ///      code, which would reject an EIP-7702 wallet's plain signature; the real token accepts it, so we do too.
    ///      `ECDSA.tryRecover` rejects malleable (high-s) signatures.
    function _isValidSignatureNow(address signer, bytes32 digest, bytes memory signature) internal view returns (bool) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) return true;
        return SignatureChecker.isValidERC1271SignatureNow(signer, digest, signature);
    }
}
