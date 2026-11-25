// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";

/// @title Fork_Base_Test
/// @notice The set-up of the fork tests (docs/ARCHITECTURE.md §13, security checklist TOK-*): the whole contract test
///         set-up, the checkers included, run on a fork of Robinhood Chain mainnet (chain id 4663) against the real
///         USDG instead of the mock.
/// @dev The fork:
///      - `ROBINHOOD_RPC_URL` names the RPC. The public one, `https://rpc.mainnet.chain.robinhood.com`, is enough.
///        Without the variable every fork test is skipped, so `forge test` never needs the network.
///      - `ROBINHOOD_FORK_BLOCK`, if set, is the block forked. The public RPC keeps only about 8 to 30 minutes of
///        state, so it can't serve an older block: without the variable each test forks the latest block, and the
///        fork workflow (`.github/workflows/fork.yml`) sets it to the latest block once, so every test of a run reads
///        the same state. Pinning an older block needs an archive RPC.
///      The real token:
///      - `usdg` is the real USDG, typed as the mock for the functions both have (transfers, approvals, EIP-3009,
///        `freeze`, `pause`, `isFrozen`, `paused`). The tests never call a mock-only function on it.
///      - `usdgAdmin` holds USDG's asset-protection (freeze) and pause roles on 4663, granted at block 57, so the
///        tests freeze and pause the real token the way Paxos would.
///      - Paxos mints through its supply controller, so `_mintUsdg` writes the balance with Foundry's `deal`.
abstract contract Fork_Base_Test is Settlement_Base_Test {
    /// @dev USDG ("Global Dollar") on Robinhood Chain mainnet.
    address internal constant REAL_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @dev The account holding USDG's asset-protection and pause roles on 4663.
    address internal constant USDG_ROLES = 0x3Af3e85f4f97De7AD0f000B724Fb77fE5ffc024B;

    /// @dev Robinhood Chain mainnet's chain id.
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    /// @dev Forks Robinhood Chain mainnet and points the tests at the real USDG, or skips every test without an RPC.
    function _useToken() internal override {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "no ROBINHOOD_RPC_URL: the fork tests need Robinhood Chain mainnet");
            return;
        }
        // Read as text, so the empty value `.env.example` leaves means "the latest block".
        string memory forkBlock = vm.envOr("ROBINHOOD_FORK_BLOCK", string(""));
        if (bytes(forkBlock).length == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, vm.parseUint(forkBlock));
        assertEq(block.chainid, ROBINHOOD_CHAIN_ID, "the fork is Robinhood Chain mainnet");
        usdg = MockUSDG(REAL_USDG);
        usdgAdmin = USDG_ROLES;
    }

    /// @dev Adds `amount` to `to`'s real USDG balance.
    function _mintUsdg(address to, uint256 amount) internal override {
        deal(address(usdg), to, usdg.balanceOf(to) + amount);
    }
}
