# `src/`: the contract

Everything here compiles into **one deployed contract**, `ManicFlashOption`, behind an ERC-1967 (UUPS) proxy.
The code is split by concern into small files and joined by inheritance. There are no separately
deployed modules, no `delegatecall` and no linked libraries. The rules are in
[`docs/CONVENTIONS.md`](../docs/CONVENTIONS.md), and the design in [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

```text
ManicFlashOption.sol        entry: the `is` list, constructor, initialize, reinitializers, _authorizeUpgrade, version()
  └─ modules/            one abstract contract per area; modules never call or override each other
       AdminModule       markets, settings, halt/pause, circuit-breaker limit and reset, relayer revocation
       TradingModule     open, sell
       SettlementModule  liquidate, settle, refundExpired, repay
       PoolModule        fund, withdraw, claim, sweepFees
       ViewsModule       read-only getters and EIP-712 hash helpers
         └─ base/FlashOptionBase      the OpenZeppelin bases, roles, and the internals modules share
              └─ base/FlashOptionStorage   the one ERC-7201 storage layout; field order is permanent
```

| Folder | What goes here |
|---|---|
| `ManicFlashOption.sol` | The entry contract only. No business logic |
| `base/` | `FlashOptionStorage` (the ERC-7201 `Layout` and its accessor) and `FlashOptionBase` (OpenZeppelin bases, roles, shared internals such as the payout helper, the signature check, the gates, the books helpers every ending shares and the circuit breaker's count) |
| `modules/` | The external functions, grouped by area: `AdminModule`, `TradingModule` (`open`, `sell`), `SettlementModule` (`liquidate`, `settle`, `refundExpired`, `repay`), `PoolModule` and `ViewsModule` (the getters and the hash helpers) |
| `interfaces/` | `IManicFlashOption` (the full ABI the backend uses), one slice per module, every event (`IManicFlashOptionEvents`), every error (`IManicFlashOptionErrors`), the role ids (`IManicFlashOptionRoles`), and `external/IUSDG` (only the token functions we call) |
| `libraries/` | `LeverageMath` (the pure maths: lines, payouts, fees, money splits and their checks, specified in [`docs/MATH.md`](../docs/MATH.md)), `ConfigLib` (the checks on a market's settings), `OrderLib` (the orders' EIP-712 type hashes and struct hashes), `BreakerLib` (circuit-breaker window and trip logic) |
| `types/` | Structs and enums at file level: `StorageTypes.sol` (stored types, **frozen: append-only**), `ParamTypes.sol` (admin parameters), `MathTypes.sol` (maths results) and `OrderTypes.sol` (signed orders, field for field as their EIP-712 type strings) |
