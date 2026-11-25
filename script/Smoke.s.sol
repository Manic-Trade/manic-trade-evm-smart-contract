// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {console} from "forge-std/console.sol";

import {ManicFlashOption} from "../src/ManicFlashOption.sol";
import {IManicFlashOptionTrading} from "../src/interfaces/IManicFlashOptionTrading.sol";
import {OpenOrder, OpenTerms, StakeAuth} from "../src/types/OrderTypes.sol";
import {ConfigParams} from "../src/types/ParamTypes.sol";
import {DurationRule, Position, Side, Status} from "../src/types/StorageTypes.sol";
import {UsdgSigner} from "../test/utils/UsdgSigner.sol";
import {BaseScript} from "./Base.s.sol";
import {MarketSettings} from "./config/MarketSettings.sol";

/// @title Smoke
/// @notice One bet through the deployed contract, the way the backend makes it: the user signs the order and the
///         stake's EIP-3009 authorisation, the first opener sends the `open` call at a price the caller gives (the
///         relayer is the price source), and after its expiry the first settler settles it. For the rehearsal on anvil
///         and the first bet on the testnet; the full smoke test is script/smoke.py.
/// @dev The user's key comes from SMOKE_USER_KEY, set only for the run: a throwaway test key, never a real wallet's.
///      The user must hold the stake (on the mock, the deployer mints it). Prices are at BTC's exponent, -8.
///
///      An open's price may be at most 5 seconds old, and running `open` on a fork of the public RPC fetches its
/// storage slot by slot, which takes longer. So `prepareOpen` only signs and returns the call, and the opener sends it
/// at
///      once with `cast send`, as the backend does:
///
///      OUT=$(SMOKE_USER_KEY=... forge script script/Smoke.s.sol --sig "prepareOpen(uint16,int64)" 1000 9500000000000 \
///        --rpc-url robinhood_testnet --json | grep '^{"logs"')
///      cast send <proxy> $(echo "$OUT" | jq -r .returns.openCall.value) --account <opener 1> --rpc-url
/// robinhood_testnet (60 seconds later)
///      forge script script/Smoke.s.sol --sig "settle(bytes32,int64)" $(echo "$OUT" | jq -r .returns.id.value) \
///        9500100000000 --rpc-url robinhood_testnet --account <settler 1> --broadcast
contract Smoke is BaseScript {
    /// @notice The bet: a $10 call for the market's shortest duration (60 seconds).
    uint64 internal constant STAKE = 10_000_000;

    /// @notice Prepares the bet on BTC at `leverage`, at `price`, published now: the `open` call the first opener
    /// sends, with the user's signed order and stake authorisation. Sends nothing.
    /// @param leverage The market's leverage.
    /// @param price The entry price.
    /// @return id The position's id.
    /// @return openCall The `open` call, for the first opener to send to the proxy.
    function prepareOpen(uint16 leverage, int64 price) external view returns (bytes32 id, bytes memory openCall) {
        ManicFlashOption proxy = ManicFlashOption(_loadRecord().proxy);
        uint256 userKey = vm.envUint("SMOKE_USER_KEY");
        address user = vm.addr(userKey);
        require(proxy.token().balanceOf(user) >= STAKE, "Smoke: the user doesn't hold the stake");
        id = keccak256(abi.encode("manic smoke", user, vm.unixTime(), block.number));
        (OpenOrder memory o, OpenTerms memory t) = _bet(id, user, leverage, price);
        openCall = abi.encodeCall(
            IManicFlashOptionTrading.open, (o, _sign(userKey, proxy.hashOpenOrder(o)), t, _stakeAuth(proxy, userKey, o))
        );
        console.log("Position id:");
        console.logBytes32(id);
        console.log("Price time", t.entryPublishTime, "expires at", t.entryPublishTime + o.durationSecs);
    }

    /// @notice Settles the bet `id` at `price`, its expiry second's price.
    /// @param id The position's id.
    /// @param price The price at expiry; it must not touch the bet's line (that bet is liquidated instead).
    function settle(bytes32 id, int64 price) external {
        Inputs memory i = _inputs();
        ManicFlashOption proxy = ManicFlashOption(_loadRecord().proxy);
        (Position memory p, uint48 endTime,) = proxy.getPosition(id);
        require(p.status == Status.Open, "Smoke: the position is not open");
        (bytes32 marketId, uint16 leverage) = proxy.marketIdAt(p.marketIdx);
        require(block.timestamp + 5 >= endTime, "Smoke: not expired yet; wait until its end time");
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256 before = proxy.token().balanceOf(p.user) + proxy.claimableOf(p.user);

        vm.startBroadcast(i.settlers[0]);
        uint256 processed = proxy.settle(marketId, leverage, price, endTime, ids);
        vm.stopBroadcast();

        (p,,) = proxy.getPosition(id);
        require(processed == 1 && p.status == Status.Closed, "Smoke: the position did not settle");
        uint256 paid = proxy.token().balanceOf(p.user) + proxy.claimableOf(p.user) - before;
        console.log("Settled; paid to the user, in base units:", paid);
    }

    /// @dev The order and terms of a $10 call on BTC at `leverage`, for the shortest duration, at `price`, published
    ///      now; θ in the middle of its range, the lowest floor and the highest cap.
    function _bet(
        bytes32 id,
        address user,
        uint16 leverage,
        int64 price
    )
        private
        view
        returns (OpenOrder memory o, OpenTerms memory t)
    {
        ConfigParams memory c = MarketSettings.btc(leverage);
        DurationRule memory rule = c.durations[0];
        uint48 now_ = _tickTime();
        o = OpenOrder({
            positionId: id,
            user: user,
            marketId: MarketSettings.BTC,
            leverage: leverage,
            side: Side.Call,
            stake: STAKE,
            durationSecs: rule.durationSecs,
            notBefore: now_,
            deadline: now_ + 60
        });
        t = OpenTerms({
            entryPrice: price,
            entryPublishTime: now_,
            thetaE7: (rule.thetaMinE7 + rule.thetaMaxE7) / 2,
            floorBps: c.floorMinBps,
            capBps: c.capMaxBps
        });
    }

    /// @dev The tick's time: the wall clock, a second back (the chain runs about a second behind), as the backend
    ///      stamps a fresh tick. Not `block.timestamp`: here that is the fork's latest block, already seconds old by
    /// the time the transaction lands, and an open's price may be at most 5 seconds old (`PriceTooOld`). Never before
    ///      the fork's block, which a test's warped clock is ahead of.
    function _tickTime() private view returns (uint48) {
        uint256 wall = vm.unixTime() / 1000;
        return uint48(wall > block.timestamp + 1 ? wall - 1 : block.timestamp);
    }

    /// @dev `key`'s 65-byte signature of `digest`.
    function _sign(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The user's EIP-3009 authorisation for the proxy to receive exactly the stake, with the position id as its
    ///      nonce, valid from a minute ago for five minutes.
    function _stakeAuth(
        ManicFlashOption proxy,
        uint256 key,
        OpenOrder memory o
    )
        private
        view
        returns (StakeAuth memory a)
    {
        a.validAfter = block.timestamp - 60;
        a.validBefore = block.timestamp + 300;
        UsdgSigner.Authorization memory auth = UsdgSigner.Authorization({
            from: o.user,
            to: address(proxy),
            value: o.stake,
            validAfter: a.validAfter,
            validBefore: a.validBefore,
            nonce: o.positionId
        });
        a.signature = _sign(key, UsdgSigner.authorizationDigest(address(proxy.token()), auth, true));
    }
}
