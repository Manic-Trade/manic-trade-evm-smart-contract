// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ManicFlashOption} from "../src/ManicFlashOption.sol";
import {ConfigParams} from "../src/types/ParamTypes.sol";
import {Market, PoolState} from "../src/types/StorageTypes.sol";
import {MockUSDG} from "../test/mocks/MockUSDG.sol";
import {BaseScript} from "./Base.s.sol";
import {MarketSettings} from "./config/MarketSettings.sol";

/// @title Configure
/// @notice Sets up the recorded proxy for trading: creates BTC's markets at the leverages chains.toml lists, each
///         switched off with its tested settings (script/config/MarketSettings.sol), switches on the ones it lists as
///         enabled, and funds the pool up to `pool_funding`. Then checks every market, field by field, and the pool.
/// @dev Creating a market is the admin's, switching one on the operator's, so on a chain where the deployer holds
///      neither (mainnet: the timelock and the Safe) this script can't run; those calls go through the Safe instead.
///      Running it again changes nothing that is already right: an existing market is not created again, an enabled
///      one is not set again, and the pool is funded only up to the target. On a mock token the deployer, its admin,
///      mints the funding first.
///
///      forge script script/Configure.s.sol --rpc-url robinhood_testnet --account <deployer> --broadcast
contract Configure is BaseScript {
    /// @notice Re-checks the markets and the pool on the live chain, sending nothing: `forge script` runs `run()`'s
    ///         checks before it broadcasts, so this is the check after (`forge script ... --sig "verify()"`, no
    ///         `--broadcast`). Unlike a dry run of `run()`, it fixes nothing first, so it can't hide what is missing.
    function verify() external view {
        Inputs memory i = _inputs();
        Record memory r = _loadRecord();
        require(r.proxy.code.length > 0, "Configure verify: no live proxy in the record");
        check(ManicFlashOption(r.proxy), i);
    }

    /// @notice Sets up, checks, and leaves the record as it is.
    function run() external {
        Inputs memory i = _inputs();
        Record memory r = _loadRecord();
        require(r.proxy.code.length > 0, "Configure: no live proxy in the record (run Deploy first)");
        ManicFlashOption proxy = ManicFlashOption(r.proxy);

        vm.startBroadcast(i.deployer);
        configure(proxy, i, r.tokenIsMock);
        vm.stopBroadcast();

        check(proxy, i);
    }

    /// @notice Creates the missing markets, switches on the listed ones that are off, and funds the pool up to the
    ///         target, from `i.deployer`. On a mock token (`mint`), mints the funding to the deployer first.
    /// @param proxy The proxy.
    /// @param i The inputs.
    /// @param mint Whether the token is our mock, whose admin is the deployer.
    function configure(ManicFlashOption proxy, Inputs memory i, bool mint) public {
        for (uint256 j; j < i.leverages.length; ++j) {
            if (!_exists(proxy, i.leverages[j])) {
                proxy.createMarket(
                    MarketSettings.BTC,
                    i.leverages[j],
                    MarketSettings.BTC_PRICE_EXPONENT,
                    MarketSettings.btc(i.leverages[j])
                );
            }
        }
        for (uint256 j; j < i.enabled.length; ++j) {
            if (!proxy.getMarket(MarketSettings.BTC, i.enabled[j]).enabled) {
                ConfigParams memory c = MarketSettings.btc(i.enabled[j]);
                c.enabled = true;
                proxy.setConfig(MarketSettings.BTC, i.enabled[j], c);
            }
        }
        uint64 total = proxy.getPool().total;
        if (total < i.poolFunding) {
            uint64 amount = i.poolFunding - total;
            IERC20 token = proxy.token();
            if (mint) MockUSDG(address(token)).mint(i.deployer, amount);
            require(token.approve(address(proxy), amount), "Configure: approve");
            proxy.fund(amount);
        }
    }

    /// @notice Reverts, naming the value, unless the proxy has exactly the markets chains.toml lists, each with its
    ///         tested settings, switched on only if listed as enabled and not paused, and a pool funded to the target.
    /// @param proxy The proxy.
    /// @param i The inputs.
    function check(ManicFlashOption proxy, Inputs memory i) public view {
        require(proxy.marketCount() == i.leverages.length, "Configure check: the number of markets");
        for (uint256 j; j < i.leverages.length; ++j) {
            uint16 leverage = i.leverages[j];
            Market memory m = proxy.getMarket(MarketSettings.BTC, leverage);
            ConfigParams memory want = MarketSettings.btc(leverage);
            want.enabled = _contains(i.enabled, leverage);
            require(m.marketId == MarketSettings.BTC && m.leverage == leverage, "Configure check: a market's key");
            require(m.priceExponent == MarketSettings.BTC_PRICE_EXPONENT, "Configure check: a price exponent");
            require(!m.paused, "Configure check: a market is paused");
            require(
                keccak256(abi.encode(_settingsOf(m))) == keccak256(abi.encode(want)),
                string.concat("Configure check: the settings of BTC at ", vm.toString(leverage), "x")
            );
        }
        PoolState memory pool = proxy.getPool();
        require(pool.total >= i.poolFunding, "Configure check: the pool's funding");
        require(proxy.token().balanceOf(address(proxy)) >= pool.total, "Configure check: the pool's balance");
        require(!proxy.halted() && !proxy.getBreaker().tripped, "Configure check: halted, or the breaker tripped");
    }

    /// @dev Whether BTC has a market at `leverage`.
    function _exists(ManicFlashOption proxy, uint16 leverage) private view returns (bool) {
        uint16 count = proxy.marketCount();
        for (uint16 j; j < count; ++j) {
            (bytes32 marketId, uint16 marketLeverage) = proxy.marketIdAt(j);
            if (marketId == MarketSettings.BTC && marketLeverage == leverage) return true;
        }
        return false;
    }

    /// @dev A stored market's settings, as `createMarket` and `setConfig` take them.
    function _settingsOf(Market memory m) private pure returns (ConfigParams memory c) {
        c.enabled = m.enabled;
        c.entryMaxAgeSecs = m.entryMaxAgeSecs;
        c.clockSkewSecs = m.clockSkewSecs;
        c.floorMinBps = m.floorMinBps;
        c.floorMaxBps = m.floorMaxBps;
        c.capMinBps = m.capMinBps;
        c.capMaxBps = m.capMaxBps;
        c.maxSellFeeBps = m.maxSellFeeBps;
        c.sellMinDelaySecs = m.sellMinDelaySecs;
        c.sellCutoffSecs = m.sellCutoffSecs;
        c.maxExposureBps = m.maxExposureBps;
        c.minStake = m.minStake;
        c.maxStake = m.maxStake;
        c.maxTotalOwed = m.maxTotalOwed;
        c.durations = m.durations;
    }
}
