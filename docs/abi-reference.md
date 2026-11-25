# ABI reference

Every function, event and error of the contract, with the selector or topic it is called, logged and
reverted by. **Generated** by `docs/tools/abi_tables.py` from the compiled `IManicFlashOption`, so do not edit it
by hand: CI fails if it is stale. The JSON ABI is `abi/IManicFlashOption.json`; what each entry does is in
[integration.md](integration.md) and in the interfaces' NatSpec. Struct parameters are written as the tuple of
their fields, in order, as the selector hashes them.

## Functions

### Admin (`IManicFlashOptionAdmin`)

| Function | Selector | Kind |
|---|---|---|
| `createMarket(bytes32,uint16,int8,(bool,uint8,uint8,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint64,uint64,uint64,(uint16,uint32,uint32,bool)[5]))` | `0x71875c40` | nonpayable |
| `initialize((address,uint48,address,address,address,address[],address[],address,uint64,address,address,uint48,uint64,uint32))` | `0x193ba9d0` | nonpayable |
| `resetBreaker()` | `0xf36c1da1` | nonpayable |
| `revokeRelayer(bytes32,address)` | `0x2511d939` | nonpayable |
| `setBreaker(uint64,uint32)` | `0xd7b3a94c` | nonpayable |
| `setConfig(bytes32,uint16,(bool,uint8,uint8,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint64,uint64,uint64,(uint16,uint32,uint32,bool)[5]))` | `0xc413f812` | nonpayable |
| `setHalted(bool)` | `0xdcc279c8` | nonpayable |
| `setPaused(bytes32,uint16,bool)` | `0x2b9bb883` | nonpayable |
| `setPoolFloor(uint64)` | `0xa009071a` | nonpayable |
| `setRecipients(address,address)` | `0x16de1335` | nonpayable |
| `setRefundDelay(uint48)` | `0x0a5e180b` | nonpayable |

### Trading (`IManicFlashOptionTrading`)

| Function | Selector | Kind |
|---|---|---|
| `open((bytes32,address,bytes32,uint16,uint8,uint64,uint16,uint48,uint48),bytes,(int64,uint48,uint32,uint16,uint16),(uint256,uint256,bytes))` | `0x977823aa` | nonpayable |
| `sell((bytes32,uint64,uint48,uint48),bytes,(int64,uint48,uint64,uint64))` | `0xc08cac15` | nonpayable |

### Settlement (`IManicFlashOptionSettlement`)

| Function | Selector | Kind |
|---|---|---|
| `liquidate(bytes32,uint16,int64,uint48,bytes32[])` | `0xf447c415` | nonpayable |
| `refundExpired(bytes32[])` | `0x9901378c` | nonpayable |
| `repay(uint256)` | `0x371fd8e6` | nonpayable |
| `settle(bytes32,uint16,int64,uint48,bytes32[])` | `0x5cd277d3` | nonpayable |

### Pool (`IManicFlashOptionPool`)

| Function | Selector | Kind |
|---|---|---|
| `claim(address)` | `0x1e83409a` | nonpayable |
| `fund(uint64)` | `0x4f9c09cc` | nonpayable |
| `sweepFees()` | `0xd113b95c` | nonpayable |
| `withdraw(uint8,uint64)` | `0x07bd870d` | nonpayable |

### Views (`IManicFlashOptionViews`)

| Function | Selector | Kind |
|---|---|---|
| `claimableOf(address)` | `0x8903ab9d` | view |
| `freeMoney()` | `0x97a09338` | view |
| `getBreaker()` | `0xeed17c9b` | view |
| `getMarket(bytes32,uint16)` | `0x06df5fa4` | view |
| `getPool()` | `0x026b1d5f` | view |
| `getPosition(bytes32)` | `0x1928b3cb` | view |
| `halted()` | `0xb9b8af0b` | view |
| `hashOpenOrder((bytes32,address,bytes32,uint16,uint8,uint64,uint16,uint48,uint48))` | `0x4d7fd963` | view |
| `hashSellOrder((bytes32,uint64,uint48,uint48))` | `0x5ca8d1d6` | view |
| `marketCount()` | `0xec979082` | view |
| `marketIdAt(uint16)` | `0x91cbf5bd` | view |
| `queueHead()` | `0x96523644` | view |
| `recipients()` | `0x0e57d4ce` | view |
| `refundDelaySecs()` | `0xe4139d63` | view |
| `token()` | `0xfc0c546a` | view |
| `version()` | `0x54fd4d50` | pure |

### Role ids (`IManicFlashOptionRoles`)

| Function | Selector | Kind |
|---|---|---|
| `GUARDIAN_ROLE()` | `0x24ea54f4` | view |
| `OPENER_ROLE()` | `0x2cfc828b` | view |
| `OPERATOR_ROLE()` | `0xf5b541a6` | view |
| `SETTLER_ROLE()` | `0x7445e85c` | view |
| `UPGRADER_ROLE()` | `0xf72c0d8b` | view |

### OpenZeppelin (roles and the EIP-712 domain)

| Function | Selector | Kind |
|---|---|---|
| `acceptDefaultAdminTransfer()` | `0xcefc1429` | nonpayable |
| `beginDefaultAdminTransfer(address)` | `0x634e93da` | nonpayable |
| `cancelDefaultAdminTransfer()` | `0xd602b9fd` | nonpayable |
| `changeDefaultAdminDelay(uint48)` | `0x649a5ec7` | nonpayable |
| `defaultAdmin()` | `0x84ef8ffc` | view |
| `defaultAdminDelay()` | `0xcc8463c8` | view |
| `defaultAdminDelayIncreaseWait()` | `0x022d63fb` | view |
| `eip712Domain()` | `0x84b0196e` | view |
| `getRoleAdmin(bytes32)` | `0x248a9ca3` | view |
| `grantRole(bytes32,address)` | `0x2f2ff15d` | nonpayable |
| `hasRole(bytes32,address)` | `0x91d14854` | view |
| `pendingDefaultAdmin()` | `0xcf6eefb7` | view |
| `pendingDefaultAdminDelay()` | `0xa1eda53c` | view |
| `renounceRole(bytes32,address)` | `0x36568abe` | nonpayable |
| `revokeRole(bytes32,address)` | `0xd547741f` | nonpayable |
| `rollbackDefaultAdminDelay()` | `0x0aa6220b` | nonpayable |

## Events

### Ours (`IManicFlashOptionEvents`)

| Event | Topic 0 | Indexed |
|---|---|---|
| `CircuitBreakerReset(address)` | `0x07663ee3f7c1099057fc9fc555efb675b77fe234386ec977b12f15d5f24fd030` | actor |
| `CircuitBreakerTripped(uint64,uint64,uint48)` | `0x7f9cf022c14fcd686d0810e06f561ffdccb6ac3575a6b2b8fa2ad95c8df84a62` | none |
| `CircuitBreakerUpdated(uint64,uint32)` | `0x0d43b94055326492f51562cbefb0be65a1cc908df22ff5527d34d4df50c44616` | none |
| `Claimed(address,uint64)` | `0xf4274452e5684f8b5cbbd49b20845bba89e9d94f83e4caa147bea3eda0928724` | account |
| `ConfigUpdated(bytes32,uint16,address,(bool,uint8,uint8,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint64,uint64,uint64,(uint16,uint32,uint32,bool)[5]))` | `0x13692d058edf0350d487dd5250e5f7b8f4a2a329b8ff7cdb2ab1b1b8d42134c6` | marketId, leverage, actor |
| `FeesSwept(address,uint64)` | `0x92b50d047432eb7fd2c813417cd6a222dd0be62d82cd2915e1358690ff4e3734` | to |
| `HaltChanged(address,bool)` | `0x1f0376571aeb1d0a1e4e46442020750b3616e3383444201e484c179309c36fe8` | actor |
| `MarketCreated(bytes32,uint16,uint16,int8)` | `0x3eb150f5ce0821110c36a9eee64552b42124169c53fc7eff33f70c32b445b036` | marketId, leverage |
| `OwedRepaid(bytes32,address,uint64,uint64,uint64,uint64)` | `0x7a8b3df661b50c23e378ceff63e612f3563fa00f5f811496aeaffa3990653b72` | positionId, user |
| `PauseChanged(bytes32,uint16,address,bool)` | `0xd8a4d2ea374f0df60d73734ea2883d6bd2f9ea4522d7ee30b45d43d1a8c0ccdf` | marketId, leverage, actor |
| `PayoutDeferred(bytes32,address,uint64)` | `0x0c2ebc8aabc50802a6671f76c89a907b42e5af1e34b9608d620dbfd552bd3f94` | positionId, to |
| `PoolFloorUpdated(uint64)` | `0x7dae8c479db03a37e93a8716838896cd88420d36e0d045bccf940f33265406df` | none |
| `PoolFunded(address,uint64)` | `0x3e2de57bb65044b2ab767b0e28ffdb8b1fa0ca62a7e08ef04c7da9a40dbebe23` | actor |
| `PoolWithdrawn(uint8,uint64,address)` | `0x9b589e10f3b1210d95a9a4331b62f1a0a89bf55f732e1b0487a3c590f5b4e442` | destination |
| `PositionLiquidated(bytes32,address,uint8,uint64,int64,int64,uint48,uint48,uint64,uint16)` | `0x8dea9a5b600a4c56d014c657cfa8c6956000a8a808e502a9ed370e0ca336d615` | positionId, user |
| `PositionOpened(bytes32,address,bytes32,uint8,uint64,int64,int8,int64,int64,uint32,uint16,uint16,uint48,uint48,uint16)` | `0x7e07ab17aef77ed6907d03af09d8bea26b7b106c398042d85eca32bacbc7eb45` | positionId, user, marketId |
| `PositionRefunded(bytes32,address,uint64)` | `0xa547cd49f01feac490fb23c90f2dbe2bac8032575914a1ef53992553d4c26ee6` | positionId, user |
| `PositionSettled(bytes32,address,uint8,uint64,int64,uint48,uint16,uint64,uint64,uint64,uint64,uint64,uint64,uint16)` | `0xdc8a95314617bec2e88a0edcc97fbd1989e7e05059a4618e34ea793c009f9db2` | positionId, user |
| `PositionSkipped(bytes32,uint8)` | `0xf4ef9e6d56b1141ff868dad5bc4deea00b4f9672c7a6c7aa9e121175516b82ab` | positionId |
| `PositionSold(bytes32,address,uint8,uint64,int64,uint48,uint16,uint64,uint64,uint64,uint64,uint64,uint16)` | `0xf3cb61c787206e2f75753d3e4eb014061aed17ca4cad85ab2e88b20b1f7d80fc` | positionId, user |
| `RecipientsUpdated(address,address)` | `0xb46243848fd4cfcaa63343d3207d276896a2fb784a5bba9c37f737170bf5fe42` | feeRecipient, rewardsRecipient |
| `RefundDelayUpdated(uint48)` | `0x0504eeba93c0f6e928e12bbc8cd015c7beae603ec2104c20b95d9a17d6495b5f` | none |

### OpenZeppelin

| Event | Topic 0 | Indexed |
|---|---|---|
| `DefaultAdminDelayChangeCanceled()` | `0x2b1fa2edafe6f7b9e97c1a9e0c3660e645beb2dcaa2d45bdbf9beaf5472e1ec5` | none |
| `DefaultAdminDelayChangeScheduled(uint48,uint48)` | `0xf1038c18cf84a56e432fdbfaf746924b7ea511dfe03a6506a0ceba4888788d9b` | none |
| `DefaultAdminTransferCanceled()` | `0x8886ebfc4259abdbc16601dd8fb5678e54878f47b3c34836cfc51154a9605109` | none |
| `DefaultAdminTransferScheduled(address,uint48)` | `0x3377dc44241e779dd06afab5b788a35ca5f3b778836e2990bdb26a2a4b2e5ed6` | newAdmin |
| `EIP712DomainChanged()` | `0x0a6387c9ea3628b88a633bb4f3b151770f70085117a15f9bf3787cda53f13d31` | none |
| `RoleAdminChanged(bytes32,bytes32,bytes32)` | `0xbd79b86ffe0ab8e8776151514217cd7cacd52c909f66475c3af44e129f0b00ff` | role, previousAdminRole, newAdminRole |
| `RoleGranted(bytes32,address,address)` | `0x2f8788117e7eff1d82e926ec794901d17c78024a50270940304540a733656f0d` | role, account, sender |
| `RoleRevoked(bytes32,address,address)` | `0xf6391f5c32d9c69d2a47ea670b442974b53935d1edc7fd64eb21e047a839171b` | role, account, sender |

## Errors

### Ours (`IManicFlashOptionErrors`)

| Error | Selector |
|---|---|
| `BatchSizeTooLarge()` | `0x7a01d654` |
| `BelowPoolFloor()` | `0xd8a1b41e` |
| `BreakerTripped()` | `0x89d13bb4` |
| `ConfigMismatch(bytes32)` | `0x46aa57be` |
| `EmptyBatch()` | `0xc2e5347d` |
| `Halted()` | `0x1ee9080f` |
| `InsufficientGasForPayout()` | `0x02a1f0b8` |
| `InvalidAmount()` | `0x2c5211c6` |
| `InvalidBreakerParams()` | `0xeb443611` |
| `InvalidLeverageParams()` | `0x9d146e41` |
| `InvalidLiquidationWindow(bytes32)` | `0x4e0f6811` |
| `InvalidMaxCount()` | `0xac38930b` |
| `InvalidPrice()` | `0x00bfc921` |
| `InvalidPriceTimestamp(bytes32)` | `0x75654fd4` |
| `InvalidRefundDelay()` | `0x206e6f02` |
| `InvalidRelayerRole(bytes32)` | `0x0b7d8727` |
| `InvalidSignature()` | `0x8baa579f` |
| `InvalidTokenDecimals(uint8)` | `0xba014b76` |
| `LeverageDisabled()` | `0x2733d0d9` |
| `LeveragePaused()` | `0x8cb09725` |
| `LiquidateInstead(bytes32)` | `0x71d3a419` |
| `LiquidationPriceNotReached(bytes32)` | `0x6531746d` |
| `MarketExists()` | `0x8fc6f59b` |
| `MathOverflow()` | `0x9d565d4e` |
| `NotExpired()` | `0xd0404f85` |
| `NothingToClaim()` | `0x969bf728` |
| `OnlyOperatorCanUnhalt()` | `0x7c56d089` |
| `OnlyOperatorCanUnpause()` | `0x6864b1a4` |
| `OpenBlockedExposure()` | `0x0752be93` |
| `OpenBlockedTotalOwed()` | `0xc18dcbab` |
| `OpenExposureNotCovered()` | `0x1008e149` |
| `OrderExpired()` | `0xc56873ba` |
| `OwedOutstanding()` | `0x2584de66` |
| `PositionIdUsed()` | `0x7a125c00` |
| `PositionNotOpen()` | `0x94e88a21` |
| `PriceBeforeOrder()` | `0xcbea3c3c` |
| `PriceFromFuture()` | `0x331ecebf` |
| `PriceTooOld()` | `0xc9cf1f8b` |
| `QueueNotEmpty()` | `0x83f48206` |
| `RefundDisabled()` | `0xff1e263c` |
| `RefundTooEarly(bytes32)` | `0xf7128202` |
| `SeedRecoveryExceeded()` | `0x54424df6` |
| `SellAmountBelowMin()` | `0x5ba60791` |
| `SellAmountExceedsValuation()` | `0x6e99e431` |
| `SellFeeTooHigh()` | `0xd4825c3a` |
| `SellNotPayable()` | `0x26b4a583` |
| `SellWindowClosed()` | `0xa25966e9` |
| `TransferAmountMismatch(uint256,uint256)` | `0xb6a9b654` |
| `UnknownMarket()` | `0xd8ac9325` |
| `UnknownPosition(bytes32)` | `0xf47ffff1` |
| `ValuationAboveCurrentPayout()` | `0xb1ace7aa` |
| `ZeroAddress()` | `0xd92e233d` |

### OpenZeppelin

| Error | Selector |
|---|---|
| `AccessControlBadConfirmation()` | `0x6697b232` |
| `AccessControlEnforcedDefaultAdminDelay(uint48)` | `0x19ca5ebb` |
| `AccessControlEnforcedDefaultAdminRules()` | `0x3fc3c27a` |
| `AccessControlInvalidDefaultAdmin(address)` | `0xc22c8022` |
| `AccessControlUnauthorizedAccount(address,bytes32)` | `0xe2517d3f` |

58 functions, 30 events and 57 errors in all.
