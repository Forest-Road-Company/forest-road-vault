/**
 * Minimal typed ABIs for the write paths (brief §8.5 / CLAUDE.md §3.3). Hand-pruned
 * from the forge artifacts to exactly the functions the app calls — plus EVERY custom
 * error the protocol can raise on those paths (merged across modules), so viem can
 * decode any revert into a named error regardless of which module in the call chain
 * raised it. No address lives here; addresses come from config/contracts.ts only.
 */

/** Union of protocol + OZ custom errors reachable from the app's write paths.
 *  Spread into each contract ABI so simulation reverts always decode. */
export const PROTOCOL_ERRORS = [
  // MintRedeemController
  {type: "error", name: "Controller_NotKYCAllowed", inputs: [{name: "account", type: "address"}]},
  {type: "error", name: "Controller_ZeroAmount", inputs: []},
  {type: "error", name: "Controller_AmountTooSmall", inputs: [{name: "usdfrAmount", type: "uint256"}]},
  {type: "error", name: "Controller_BackingInvariantViolated", inputs: [{name: "supply", type: "uint256"}, {name: "backing", type: "uint256"}]},
  {type: "error", name: "Controller_ZeroAddress", inputs: []},
  // sUSDfr
  {type: "error", name: "SUSDfr_QueueOnly", inputs: []},
  {type: "error", name: "SUSDfr_TransferBlocked", inputs: [{name: "from", type: "address"}, {name: "to", type: "address"}]},
  {type: "error", name: "SUSDfr_VestingPeriodTooLong", inputs: [{name: "period", type: "uint64"}]},
  {type: "error", name: "SUSDfr_ManagementFeeTooHigh", inputs: [{name: "requestedBps", type: "uint16"}]},
  {type: "error", name: "SUSDfr_PerformanceFeeTooHigh", inputs: [{name: "requestedBps", type: "uint16"}]},
  {type: "error", name: "SUSDfr_FeeAccrualReentrant", inputs: []},
  {type: "error", name: "SUSDfr_FeeRecipientNotExempt", inputs: [{name: "recipient", type: "address"}]},
  // USDfr
  {type: "error", name: "USDfr_TransferNotAllowed", inputs: [{name: "from", type: "address"}, {name: "to", type: "address"}]},
  // RedemptionQueue
  {type: "error", name: "Queue_ZeroAmount", inputs: []},
  {type: "error", name: "Queue_BelowMinRedemption", inputs: [{name: "value", type: "uint256"}, {name: "minimum", type: "uint256"}]},
  {type: "error", name: "Queue_HeadNotRedeemable", inputs: [{name: "requestId", type: "uint256"}, {name: "sharesRemaining", type: "uint256"}]},
  {type: "error", name: "Queue_UnknownRequest", inputs: [{name: "requestId", type: "uint256"}]},
  {type: "error", name: "Queue_NotRequestOwner", inputs: [{name: "requestId", type: "uint256"}, {name: "caller", type: "address"}]},
  {type: "error", name: "Queue_NothingClaimable", inputs: [{name: "requestId", type: "uint256"}]},
  {type: "error", name: "Queue_EpochNotOver", inputs: [{name: "endsAt", type: "uint64"}]},
  {type: "error", name: "Queue_NotSettling", inputs: []},
  {type: "error", name: "Queue_AllInCooldown", inputs: [{name: "eligibleAt", type: "uint256"}]},
  {type: "error", name: "Queue_BadParams", inputs: []},
  {type: "error", name: "Queue_NoLiquidity", inputs: []},
  // ReserveManager errors surface through MintRedeemController.redeem
  {type: "error", name: "ReserveManager_InsufficientIdleValue", inputs: [{name: "requestedValue", type: "uint256"}, {name: "idleValue", type: "uint256"}]},
  {type: "error", name: "Queue_NoLiquidity", inputs: []},
  // OZ shared
  {type: "error", name: "EnforcedPause", inputs: []},
  {type: "error", name: "ReentrancyGuardReentrantCall", inputs: []},
  {type: "error", name: "SafeERC20FailedOperation", inputs: [{name: "token", type: "address"}]},
  {type: "error", name: "ERC20InsufficientBalance", inputs: [{name: "sender", type: "address"}, {name: "balance", type: "uint256"}, {name: "needed", type: "uint256"}]},
  {type: "error", name: "ERC20InsufficientAllowance", inputs: [{name: "spender", type: "address"}, {name: "allowance", type: "uint256"}, {name: "needed", type: "uint256"}]},
  {type: "error", name: "ERC4626ExceededMaxDeposit", inputs: [{name: "receiver", type: "address"}, {name: "assets", type: "uint256"}, {name: "max", type: "uint256"}]},
  {type: "error", name: "ERC4626ExceededMaxRedeem", inputs: [{name: "owner", type: "address"}, {name: "shares", type: "uint256"}, {name: "max", type: "uint256"}]},
  {type: "error", name: "AccessControlUnauthorizedAccount", inputs: [{name: "account", type: "address"}, {name: "neededRole", type: "bytes32"}]},
] as const;

/** Plain ERC-20 surface (tUSDC, USDfr, and sUSDfr share-token ops). */
export const ERC20_ABI = [
  {type: "function", name: "balanceOf", stateMutability: "view", inputs: [{name: "account", type: "address"}], outputs: [{type: "uint256"}]},
  {type: "function", name: "allowance", stateMutability: "view", inputs: [{name: "owner", type: "address"}, {name: "spender", type: "address"}], outputs: [{type: "uint256"}]},
  {type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{name: "spender", type: "address"}, {name: "value", type: "uint256"}], outputs: [{type: "bool"}]},
  {type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{type: "uint8"}]},
  {type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  ...PROTOCOL_ERRORS,
] as const;

/** TESTNET mock stablecoin: standard ERC-20 plus a public faucet `mint`. */
export const TEST_STABLE_ABI = [
  {type: "function", name: "mint", stateMutability: "nonpayable", inputs: [{name: "to", type: "address"}, {name: "amount", type: "uint256"}], outputs: []},
  ...ERC20_ABI,
] as const;

export const CONTROLLER_ABI = [
  {type: "function", name: "mint", stateMutability: "nonpayable", inputs: [{name: "usdcAmount", type: "uint256"}], outputs: [{name: "usdfrOut", type: "uint256"}]},
  {type: "function", name: "redeem", stateMutability: "nonpayable", inputs: [{name: "usdfrAmount", type: "uint256"}], outputs: [{name: "usdcOut", type: "uint256"}]},
  {type: "function", name: "paused", stateMutability: "view", inputs: [], outputs: [{type: "bool"}]},
  ...PROTOCOL_ERRORS,
] as const;

/** sUSDfr share decimals: 18 (USDfr) + 6 (ERC-4626 anti-inflation decimals offset).
 *  Confirmed against the live vault's decimals() = 24. */
export const SHARE_DECIMALS = 24;

export const VAULT_ABI = [
  {type: "function", name: "deposit", stateMutability: "nonpayable", inputs: [{name: "assets", type: "uint256"}, {name: "receiver", type: "address"}], outputs: [{name: "shares", type: "uint256"}]},
  {type: "function", name: "previewDeposit", stateMutability: "view", inputs: [{name: "assets", type: "uint256"}], outputs: [{type: "uint256"}]},
  {type: "function", name: "convertToAssets", stateMutability: "view", inputs: [{name: "shares", type: "uint256"}], outputs: [{type: "uint256"}]},
  // ADR-0022 Option Y: exits price on the CONSERVATIVE NAV (totalAssets minus
  // declared-but-unrealized impairment), not the deposit NAV. Any redemption preview MUST
  // use this, or the UI overstates what a user receives during exactly the window that
  // matters. `convertToAssets` above remains the DEPOSIT price and is not an exit quote.
  {type: "function", name: "previewRedeem", stateMutability: "view", inputs: [{name: "shares", type: "uint256"}], outputs: [{type: "uint256"}]},
  {type: "function", name: "currentExchangeRate", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "totalAssets", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "unvestedYield", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  // The vesting WINDOW, distinct from the stream balance above. `unvestedYield()` returns
  // zero for three different reasons (no window, no stream, stream complete), so it cannot
  // be used to state whether streaming is configured (audit R15-03).
  {type: "function", name: "yieldVestingPeriod", stateMutability: "view", inputs: [], outputs: [{type: "uint64"}]},
  {type: "function", name: "impairmentSource", stateMutability: "view", inputs: [], outputs: [{type: "address"}]},
  {type: "function", name: "performanceFeeBps", stateMutability: "view", inputs: [], outputs: [{type: "uint16"}]},
  {type: "function", name: "maxPerformanceFeeBps", stateMutability: "pure", inputs: [], outputs: [{type: "uint16"}]},
  {type: "function", name: "managementFeeBps", stateMutability: "view", inputs: [], outputs: [{type: "uint16"}]},
  {type: "function", name: "maxManagementFeeBps", stateMutability: "pure", inputs: [], outputs: [{type: "uint16"}]},
  {type: "function", name: "managementFeeYear", stateMutability: "pure", inputs: [], outputs: [{type: "uint64"}]},
  {type: "function", name: "highWaterMark", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "feeExchangeRate", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "feeRecipient", stateMutability: "view", inputs: [], outputs: [{type: "address"}]},
  {type: "function", name: "lastFeeAccrual", stateMutability: "view", inputs: [], outputs: [{type: "uint64"}]},
  ...ERC20_ABI,
] as const;

/** Narrow ADR-0022/0027 source used to decide whether the queued-exit warning is real.
 *  Reading the impairment itself avoids comparing deposit and exit previews fetched at
 *  different blocks while repayment or impairment state can move. */
export const IMPAIRMENT_SOURCE_ABI = [
  {type: "function", name: "pendingSeniorImpairment", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  // ADR-0031 gross mark. `pendingSeniorImpairment` is netted against junior capital and so
  // understates the performance-fee base; the deferred fee that crystallizes on a cure is
  // sized on THIS figure. Without it the interface cannot compute deferred exposure at all
  // (audit R14-03).
  {type: "function", name: "performanceFeeImpairment", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
] as const;

/** Vault events used for fee history, optional-stream observability, and wallet cost
 * basis. Historical senior income is derived from Waterfall `Distributed.toVault`,
 * which covers both the launch zero-period path and optional streaming without
 * double-counting rollovers. */
export const VAULT_HISTORY_ABI = [
  {
    type: "event",
    name: "YieldStreamStarted",
    anonymous: false,
    inputs: [
      {name: "added", type: "uint256", indexed: false},
      {name: "streamTotal", type: "uint256", indexed: false},
      {name: "period", type: "uint64", indexed: false},
    ],
  },
  {
    type: "event",
    name: "ManagementFeeAccrued",
    anonymous: false,
    inputs: [
      {name: "elapsed", type: "uint256", indexed: false},
      {name: "feeAssets", type: "uint256", indexed: false},
      {name: "feeShares", type: "uint256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "PerformanceFeeAccrued",
    anonymous: false,
    inputs: [
      {name: "oldHighWaterMark", type: "uint256", indexed: false},
      {name: "newHighWaterMark", type: "uint256", indexed: false},
      {name: "profitAssets", type: "uint256", indexed: false},
      {name: "feeAssets", type: "uint256", indexed: false},
      {name: "feeShares", type: "uint256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "HighWaterMarkAdjusted",
    anonymous: false,
    inputs: [
      {name: "oldHighWaterMark", type: "uint256", indexed: false},
      {name: "newHighWaterMark", type: "uint256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "ManagementFeeSet",
    anonymous: false,
    inputs: [
      {name: "oldFeeBps", type: "uint16", indexed: false},
      {name: "newFeeBps", type: "uint16", indexed: false},
    ],
  },
  {
    type: "event",
    name: "PerformanceFeeSet",
    anonymous: false,
    inputs: [
      {name: "oldFeeBps", type: "uint16", indexed: false},
      {name: "newFeeBps", type: "uint16", indexed: false},
    ],
  },
  {
    type: "event",
    name: "VaultFeeRecipientSet",
    anonymous: false,
    inputs: [
      {name: "oldRecipient", type: "address", indexed: true},
      {name: "newRecipient", type: "address", indexed: true},
    ],
  },
  {
    type: "event",
    name: "Deposit",
    anonymous: false,
    inputs: [
      {name: "sender", type: "address", indexed: true},
      {name: "owner", type: "address", indexed: true},
      {name: "assets", type: "uint256", indexed: false},
      {name: "shares", type: "uint256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "Transfer",
    anonymous: false,
    inputs: [
      {name: "from", type: "address", indexed: true},
      {name: "to", type: "address", indexed: true},
      {name: "value", type: "uint256", indexed: false},
    ],
  },
] as const;

export const QUEUE_ABI = [
  {
    type: "event",
    name: "RedemptionRequested",
    anonymous: false,
    inputs: [
      {name: "requestId", type: "uint256", indexed: true},
      {name: "owner", type: "address", indexed: true},
      {name: "shares", type: "uint256", indexed: false},
      {name: "epoch", type: "uint256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "RequestFilled",
    anonymous: false,
    inputs: [
      {name: "requestId", type: "uint256", indexed: true},
      {name: "shares", type: "uint256", indexed: false},
      {name: "assets", type: "uint256", indexed: false},
      {name: "epoch", type: "uint256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "Claimed",
    anonymous: false,
    inputs: [
      {name: "requestId", type: "uint256", indexed: true},
      {name: "owner", type: "address", indexed: true},
      {name: "assets", type: "uint256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "EpochClosed",
    anonymous: false,
    inputs: [
      {name: "epoch", type: "uint256", indexed: true},
      {name: "budget", type: "uint256", indexed: false},
      {name: "distributed", type: "uint256", indexed: false},
      {name: "nextEpochEndsAt", type: "uint64", indexed: false},
    ],
  },
  {
    type: "event",
    name: "RedeemCooldownSet",
    anonymous: false,
    inputs: [{name: "cooldown", type: "uint64", indexed: false}],
  },
  {type: "function", name: "requestRedeem", stateMutability: "nonpayable", inputs: [{name: "shares", type: "uint256"}], outputs: [{name: "requestId", type: "uint256"}]},
  {type: "function", name: "claim", stateMutability: "nonpayable", inputs: [{name: "requestId", type: "uint256"}], outputs: [{name: "assets", type: "uint256"}]},
  {type: "function", name: "request", stateMutability: "view", inputs: [{name: "requestId", type: "uint256"}], outputs: [{name: "owner", type: "address"}, {name: "sharesRemaining", type: "uint256"}, {name: "assetsClaimable", type: "uint256"}, {name: "epochRequested", type: "uint256"}, {name: "requestedAt", type: "uint256"}]},
  {type: "function", name: "totalRequests", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "currentEpoch", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "epochEndsAt", stateMutability: "view", inputs: [], outputs: [{type: "uint64"}]},
  {type: "function", name: "isSettling", stateMutability: "view", inputs: [], outputs: [{type: "bool"}]},
  {type: "function", name: "redeemCooldown", stateMutability: "view", inputs: [], outputs: [{type: "uint64"}]},
  {type: "function", name: "eligibleToSettleAt", stateMutability: "view", inputs: [{name: "requestId", type: "uint256"}], outputs: [{type: "uint256"}]},
  {type: "function", name: "availableLiquidity", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "totalQueuedShares", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  ...PROTOCOL_ERRORS,
] as const;

export const COMPLIANCE_ABI = [
  {type: "function", name: "isAllowed", stateMutability: "view", inputs: [{name: "account", type: "address"}], outputs: [{type: "bool"}]},
] as const;

export const RESERVES_ABI = [
  {type: "function", name: "idleReserve", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "deployedPrincipal", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "deployedTo", stateMutability: "view", inputs: [{name: "tokenId", type: "uint256"}], outputs: [{type: "uint256"}]},
  {type: "function", name: "totalBackingValue", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
] as const;

export const BRIDGE_ABI = [
  {type: "function", name: "totalOriginated", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {
    type: "function",
    name: "facility",
    stateMutability: "view",
    inputs: [{name: "tokenId", type: "uint256"}],
    outputs: [
      {
        type: "tuple",
        components: [
          {name: "classId", type: "uint256"},
          {name: "borrowerId", type: "bytes32"},
          {name: "stateId", type: "bytes32"},
          {name: "principal", type: "uint256"},
          {name: "ltvBps", type: "uint16"},
          {name: "interestRateBps", type: "uint16"},
          {name: "maturity", type: "uint64"},
          {name: "fundingRecipient", type: "address"},
          {name: "paymentInterval", type: "uint64"},
          {name: "nextPaymentDue", type: "uint64"},
          {name: "rateType", type: "uint8"},
          {name: "dayCountConvention", type: "uint8"},
          {name: "renewable", type: "bool"},
          {name: "paymentScheduleHash", type: "bytes32"},
          {name: "rateIndexRef", type: "bytes32"},
          {name: "renewalTermsHash", type: "bytes32"},
          {name: "offchainRef", type: "bytes32"},
          {name: "state", type: "uint8"},
        ],
      },
    ],
  },
] as const;

/** Facility origination history used to attach each funded token id to its
 * collateral class. Origination alone is not used as the default-rate
 * denominator because a Pending facility may be cancelled before capital moves. */
export const BRIDGE_HISTORY_ABI = [
  {
    type: "event",
    name: "Originated",
    anonymous: false,
    inputs: [
      {name: "tokenId", type: "uint256", indexed: true},
      {name: "classId", type: "uint256", indexed: true},
      {name: "borrowerId", type: "bytes32", indexed: true},
      {name: "termsHash", type: "bytes32", indexed: false},
    ],
  },
] as const;

export const WATERFALL_ABI = [
  {type: "function", name: "protocolFeeBps", stateMutability: "view", inputs: [], outputs: [{type: "uint16"}]},
  {type: "function", name: "feeRecipient", stateMutability: "view", inputs: [], outputs: [{type: "address"}]},
] as const;

/** Actual protocol-revenue events. Summing event fields is preferable to reading
 * the fee recipient's current balance, which can be transferred and is therefore
 * not a revenue ledger. */
export const WATERFALL_HISTORY_ABI = [
  {
    type: "event",
    name: "Funded",
    anonymous: false,
    inputs: [
      {name: "tokenId", type: "uint256", indexed: true},
      {name: "recipient", type: "address", indexed: true},
      {name: "principal", type: "uint256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "OriginationFeeCharged",
    anonymous: false,
    inputs: [
      {name: "tokenId", type: "uint256", indexed: true},
      {name: "classId", type: "uint256", indexed: true},
      {name: "fee", type: "uint256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "Distributed",
    anonymous: false,
    inputs: [
      {name: "tokenId", type: "uint256", indexed: true},
      {name: "paymentId", type: "bytes32", indexed: true},
      {name: "payer", type: "address", indexed: true},
      {name: "interest", type: "uint256", indexed: false},
      {name: "principal", type: "uint256", indexed: false},
      {name: "fee", type: "uint256", indexed: false},
      {name: "toVault", type: "uint256", indexed: false},
    ],
  },
] as const;

/** Realized principal write-offs. The `loss` field is already net of principal
 * recovery processed before write-off; the remaining fields identify which
 * capital layer absorbed that loss and are not added again. */
export const DEFAULT_HISTORY_ABI = [
  {
    type: "event",
    name: "LossRealized",
    anonymous: false,
    inputs: [
      {name: "tokenId", type: "uint256", indexed: true},
      {name: "classId", type: "uint256", indexed: true},
      {name: "loss", type: "uint256", indexed: false},
      {name: "curatorAbsorbed", type: "uint256", indexed: false},
      {name: "backstopCovered", type: "uint256", indexed: false},
      {name: "depositorLoss", type: "uint256", indexed: false},
    ],
  },
] as const;

export const ATTESTATION_ORACLE_ABI = [
  {
    type: "function",
    name: "latestValuation",
    stateMutability: "view",
    inputs: [{name: "facilityId", type: "uint256"}],
    outputs: [
      {name: "value", type: "uint256"},
      {name: "asOf", type: "uint64"},
    ],
  },
] as const;

export const CURATOR_ABI = [
  {
    type: "function",
    name: "poolBalance",
    stateMutability: "view",
    inputs: [{name: "classId", type: "uint256"}],
    outputs: [{type: "uint256"}],
  },
] as const;

export const POINTS_ABI = [
  {type: "function", name: "pointsOfWallet", stateMutability: "view", inputs: [{name: "wallet", type: "address"}], outputs: [{type: "uint256"}]},
  {type: "function", name: "pointsBreakdown", stateMutability: "view", inputs: [{name: "wallet", type: "address"}], outputs: [{name: "fromShares", type: "uint256"}, {name: "fromUSDfr", type: "uint256"}, {name: "fromCurator", type: "uint256"}]},
  {type: "function", name: "trackedBalances", stateMutability: "view", inputs: [{name: "wallet", type: "address"}], outputs: [{name: "shares", type: "uint256"}, {name: "usdfr", type: "uint256"}]},
  {type: "function", name: "curatorTracked", stateMutability: "view", inputs: [{name: "wallet", type: "address"}, {name: "classId", type: "uint256"}], outputs: [{type: "uint256"}]},
  {type: "function", name: "curatorPointsInClass", stateMutability: "view", inputs: [{name: "wallet", type: "address"}, {name: "classId", type: "uint256"}], outputs: [{type: "uint256"}]},
  {type: "function", name: "curatorFreezeStatus", stateMutability: "view", inputs: [{name: "wallet", type: "address"}, {name: "classId", type: "uint256"}], outputs: [{name: "frozen", type: "bool"}, {name: "frozenAt", type: "uint64"}]},
  {type: "function", name: "ratePerUnitDay", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "usdfrMultiplierBps", stateMutability: "view", inputs: [], outputs: [{type: "uint32"}]},
  {type: "function", name: "curatorMultiplierBps", stateMutability: "view", inputs: [], outputs: [{type: "uint32"}]},
  {type: "function", name: "rateEpochCount", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
] as const;

export const SGROVE_ABI = [
  {type: "function", name: "coverageCapacity", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "coverageReserve", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
] as const;

export const REGISTRY_ABI = [
  {type: "function", name: "totalBookExposure", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {
    type: "function",
    name: "classParams",
    stateMutability: "view",
    inputs: [{name: "classId", type: "uint256"}],
    outputs: [
      {
        type: "tuple",
        components: [
          {name: "name", type: "string"},
          {name: "model", type: "uint8"},
          {name: "active", type: "bool"},
          {name: "maxLtvBps", type: "uint16"},
          {name: "maxMaturity", type: "uint64"},
          {name: "concentrationLimitBps", type: "uint16"},
          {name: "marginCallLtvBps", type: "uint16"},
          {name: "liquidationLtvBps", type: "uint16"},
          {name: "maxMarkAge", type: "uint64"},
        ],
      },
    ],
  },
] as const;
