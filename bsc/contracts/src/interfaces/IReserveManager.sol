// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IReserveManager - BSC instance, multi-asset reserve
/// @notice Treasury for a governed registry of reserve stablecoins and for deployed facility
///         principal. USD values use 18 decimals; every token amount is that asset's native units.
/// @dev BSC instance (ADR-0037 D1/D5(d)): the reserve custodies MORE THAN ONE stablecoin, each with
///      a per-asset scale recorded at listing.
///
///      THERE IS STILL NO FREE ELECTION OF A PAYOUT ASSET, AND THIS WARNING IS REWRITTEN RATHER
///      THAN DELETED (Forest Road direction 2026-09-07). ADR-0038 opened a single-asset exit and the
///      owner then narrowed it: a depositor withdraws THE ASSET THEY DEPOSITED, capped by their own
///      deposit record, and never an asset of their choosing. That cap is the security property. It
///      is what stops a holder converting an impaired asset into a sound one at the expense of the
///      holders who stay, which free election would have allowed and which the priced mint alone
///      does not close for a holder who was already holding USDfr when an asset depegged.
///      Everything beyond the record pays the PRO-RATA BASKET, which involves no choice and
///      therefore shifts no currency risk. A recorded asset the reserve cannot currently fund
///      becomes a deferred claim ON THAT ASSET, never a basket payment, for the same reason.
///
///      Any swap to a single asset still happens in a separate, non-upgradeable periphery router,
///      in the redeemer's own transaction, on tokens already in the redeemer's wallet. This
///      contract never learns that a router exists.
interface IReserveManager {
    /// @notice Lifecycle of one per-asset custody-loss adjudication (ADR-0033).
    /// @dev `None` also means "never issued". Ids are never reissued, so a non-`None` state is the
    ///      arm's own used-marker; there is no shared, never-cleared marker (Corrovera DV-02).
    enum ArmState {
        None,
        Armed,
        Ratified,
        Finalized
    }

    /// @notice A flattened, read-only projection of one registry row plus its derived aggregates.
    /// @dev Returned as a struct so a consumer takes ONE reading of one state. Enumerating the same
    ///      quantity twice across several calls is how two views of one number diverge.
    struct ReserveAssetView {
        address asset;
        uint8 decimals;
        bool listed;
        bool frozenMint;
        bool frozenRedeem;
        uint16 mintFeeBps;
        uint32 listedAt;
        uint64 scale;
        uint256 units;
        uint256 cap;
        uint256 recognizedCapLoss;
        uint256 custodyShortfallUnits;
        uint256 deferredUnits;
        uint256 payableValue;
        uint256 backingContribution;
    }

    // --------------------------- registry events ---------------------------

    /// @notice Governance admitted a reserve asset. `index` is its permanent position in the
    ///         append-only listing order the basket allocation and dust rule depend on.
    event ReserveAssetListed(
        address indexed asset,
        uint8 decimals,
        uint64 scale,
        uint256 cap,
        uint16 mintFeeBps,
        bytes32 indexed admissionEvidenceHash,
        uint256 index
    );
    /// @notice Governance changed one asset's 18-decimal exposure ceiling.
    event ReserveAssetCapSet(address indexed asset, uint256 previousCap, uint256 newCap, bytes32 indexed evidenceHash);
    /// @notice A cap cut below the standing tally was recognized as a permanent backing mark.
    /// @dev Raising the cap back does NOT restore it (ADR-0025: up only on proof).
    event ReserveAssetCapLossRecognized(
        address indexed asset,
        uint256 contributionBefore,
        uint256 contributionAfter,
        uint256 recognized,
        bytes32 indexed evidenceHash
    );
    /// @notice Governance changed one asset's mint fee. The fee is carved by the controller.
    event ReserveAssetMintFeeSet(address indexed asset, uint16 previousBps, uint16 newBps);
    /// @notice One asset's mint and redeem freeze flags reached the stated state.
    event ReserveAssetFreezeSet(address indexed asset, bool frozenMint, bool frozenRedeem);

    // --------------------------- custody events ----------------------------

    /// @notice A reserve asset was pulled into recorded idle custody.
    event AssetDeposited(address indexed asset, address indexed from, uint256 amount, uint256 credited);
    /// @notice A pro-rata basket was allocated against recorded idle custody.
    event BasketReleased(address indexed to, uint256 requestedValue, uint256 valuePaid, uint256 legCount);
    /// @notice One basket leg was delivered to the holder.
    event BasketLegPaid(address indexed to, address indexed asset, uint256 amount, uint256 value);
    /// @notice One basket leg could not be delivered and became a claimable escrow entry.
    /// @dev The tally was ALREADY debited; the holder pulls it with `claimDeferredLeg`.
    event BasketLegDeferred(address indexed to, address indexed asset, uint256 amount, uint256 value);
    /// @notice A holder pulled a previously deferred basket leg.
    event DeferredLegClaimed(address indexed holder, address indexed asset, uint256 amount);
    /// @notice A deposit was credited to a holder's deposit record (ADR-0038).
    /// @param holder The address whose record grew; NEVER the address the tokens came from when
    ///        those differ, because the record must follow the depositor, not the transfer leg.
    /// @param asset The deposited asset.
    /// @param units Native units added to the record.
    /// @param recordAfter The holder's full record in this asset after the credit.
    event DepositRecorded(address indexed holder, address indexed asset, uint256 units, uint256 recordAfter);
    /// @notice A record-capped exit drew a holder's own recorded units of one asset.
    /// @param holder The redeemer.
    /// @param asset The recorded asset drawn.
    /// @param units Native units drawn from the record (delivered plus escrowed as a claim).
    /// @param recordAfter The holder's remaining record in this asset.
    event DepositRecordDrawn(address indexed holder, address indexed asset, uint256 units, uint256 recordAfter);
    /// @notice A recorded draw could not be funded from the idle tally and became a deferred claim.
    /// @dev The holder is deliberately NOT paid the pro-rata basket here. Paying the basket would
    ///      hand them assets other holders deposited, which is exactly the transfer the record cap
    ///      exists to close. The claim's value is removed from backing at this moment.
    /// @param holder The redeemer.
    /// @param asset The asset the claim is denominated in.
    /// @param units Native units promised.
    /// @param value 18-decimal par value of the promise.
    event PendingClaimEscrowed(address indexed holder, address indexed asset, uint256 units, uint256 value);
    /// @notice A holder pulled units against a previously escrowed pending claim.
    event PendingClaimSettled(address indexed holder, address indexed asset, uint256 units, uint256 remaining);
    /// @notice A record-capped exit completed.
    /// @param to The redeemer.
    /// @param requestedValue The 18-decimal value the controller asked to settle.
    /// @param recordedValue Value settled out of the holder's OWN record, at one to one.
    /// @param basketValue Value settled through the proportional basket for the remainder.
    /// @param claimValue The part of `recordedValue` promised rather than paid in cash.
    /// @param valuePaid Total 18-decimal value settled, delivered plus escrowed.
    event RecordedExitReleased(
        address indexed to,
        uint256 requestedValue,
        uint256 recordedValue,
        uint256 basketValue,
        uint256 claimValue,
        uint256 valuePaid
    );

    // ---------------------------- price events -----------------------------

    /// @notice A signed reserve-asset price was latched into reserve storage (ADR-0038).
    /// @param asset The listed reserve asset.
    /// @param previousPrice The value this replaces; zero on the first push.
    /// @param price The 18-decimal relative price now standing; `1e18` is par.
    /// @param asOf The ATTESTED observation time of `price`, not the submission time.
    /// @param relayer Whoever paid for the sync. Carries no authority whatsoever.
    event ReserveAssetPriceSynced(
        address indexed asset, uint256 previousPrice, uint256 price, uint64 asOf, address indexed relayer
    );
    /// @notice Governance set the global price guards and the oracle they are verified against.
    event ReservePriceGuardsSet(address indexed oracle, uint64 maxAge, uint16 maxDeviationBps);
    /// @notice Governance set one asset's absolute mint floor.
    event ReserveAssetPriceFloorSet(address indexed asset, uint256 previousFloor, uint256 floor);

    /// @notice A permissionless reconciliation lowered a tally to live custody and latched the gap.
    event IdleUnitsReconciled(
        address indexed asset, uint256 owed, uint256 live, uint256 shortfall, uint256 latchedShortfall
    );
    /// @notice Returned units cured part of an un-ratified custody latch.
    event CustodyShortfallCured(address indexed asset, uint256 credited, uint256 remainingLatch);
    /// @notice A custody loss outside the idle tally was recorded or restored against delivered tokens.
    event UnappliedCustodyLossUpdated(address indexed asset, uint256 previousUnits, uint256 units, uint256 totalValue);
    /// @notice An adjudicated custody loss was recognized against one asset's idle backing.
    event IdleUnitsWrittenDown(address indexed asset, uint256 value, uint256 remainingIdleValue);
    /// @notice Returned units were credited against one arm's written-down recovery capacity.
    event RecoveredIdleUnitsCredited(
        uint256 indexed armId, address indexed asset, uint256 nativeUnits, uint256 value, bytes32 indexed evidenceHash
    );

    // --------------------------- cascade events ----------------------------

    /// @notice A custody loss reduced backing and fixed the supply reduction the cascade must absorb.
    event ReserveLossRecognized(
        uint256 indexed incidentId, uint256 backingReduction, uint256 surplusAbsorbed, uint256 supplyReductionRequired
    );
    /// @notice The complete surplus-to-senior allocation of one recognized custody loss.
    /// @dev `backstopCovered` is PERMANENTLY ZERO on this instance (ADR-0037 D3a(ii): no cascade
    ///      layer two). It is retained so every custody-loss log carries a machine-readable zero
    ///      where layer two would have been, making the disclosure auditable from the chain.
    event ReserveLossAllocated(
        uint256 indexed incidentId,
        uint256 backingReduction,
        uint256 surplusAbsorbed,
        uint256 curatorAbsorbed,
        uint256 backstopCovered,
        uint256 seniorBurned,
        uint256 residualDeficit
    );
    /// @notice The controller used for supply, backing, and loss-burn checks changed.
    event LossControllerSet(address indexed previousController, address indexed newController);
    /// @notice The ordered custody cascade and the governance timing source were wired.
    /// @dev Two layers only: `curator` first-loss, then the senior `vault`.
    event ReserveLossModulesSet(address indexed curator, address indexed vault, address indexed timelock);
    /// @notice A Guardian created a persistent per-asset reserve-loss interlock.
    event ReserveLossArmed(
        uint256 indexed armId, address indexed asset, uint256 indexed incidentId, bytes32 evidenceHash
    );
    /// @notice Governance cancelled an unratified arm and disabled future Guardian arms.
    event ReserveLossArmCancelled(uint256 indexed armId, address indexed asset, bytes32 indexed evidenceHash);
    /// @notice A reconciled false alarm was closed while independent credit marks were retained.
    event UnratifiedReserveLossArmCancelled(
        uint256 indexed armId, address indexed asset, bytes32 indexed evidenceHash, uint256 retainedCreditImpairment
    );
    /// @notice Governance closed a ratified arm and disabled future Guardian arms.
    event ReserveLossArmFinalized(
        uint256 indexed armId, address indexed asset, uint256 indexed incidentId, bytes32 evidenceHash
    );
    /// @notice Governance ratified and executed one asset's latched custody shortfall.
    event ReserveLossRatified(
        uint256 indexed armId,
        address indexed asset,
        uint256 indexed incidentId,
        uint256 approvedMaxLoss,
        uint256 actualLoss,
        bytes32 evidenceHash
    );
    /// @notice Governance enabled or disabled creation of new Guardian reserve-loss arms.
    event GuardianReserveLossArmsEnabled(bool enabled);
    /// @notice A cascade changed the latched unabsorbed reserve deficit.
    event ReserveDeficitUpdated(uint256 indexed incidentId, uint256 previousDeficit, uint256 currentDeficit);
    /// @notice Governance cleared a cured reserve-deficit latch with supporting evidence.
    event ReserveDeficitResolved(uint256 previousDeficit, bytes32 evidenceHash);

    // --------------------------- credit events -----------------------------

    /// @notice A facility's funding asset was bound on its first credit-side act.
    event FacilityAssetBound(uint256 indexed facilityId, address indexed asset);
    /// @notice Idle units became deployed principal for a facility.
    event PrincipalDeployed(uint256 indexed facilityId, address indexed asset, uint256 amount, uint256 value);
    /// @notice A retained origination fee became additional facility principal.
    event FeeCapitalized(uint256 indexed facilityId, address indexed asset, uint256 amount);

    /// @notice Contractually accrued PIK interest joined a facility's deployed principal.
    /// @dev No cash moved. Unlike `FeeCapitalized`, there is no retained cash behind this: the
    ///      borrower simply owes a larger balance. `deployedAfter` is published so the register can
    ///      reconstruct the facility's balance history from logs alone (CLAUDE.md section 3.1).
    /// @param facilityId The facility.
    /// @param asset The facility's bound asset.
    /// @param amount 18-decimal value capitalised.
    /// @param deployedAfter The facility's deployed principal after the act.
    event PikCapitalized(uint256 indexed facilityId, address indexed asset, uint256 amount, uint256 deployedAfter);
    /// @notice A cash receipt increased idle custody and reduced the stated principal leg.
    event PaymentReceived(
        uint256 indexed facilityId,
        address indexed asset,
        address indexed payer,
        uint256 amount,
        uint256 principalReturned
    );
    /// @notice Realized facility principal was removed from backing.
    event PrincipalWrittenDown(uint256 indexed facilityId, uint256 amount);
    /// @notice Governance added an evidence-backed conservative facility impairment.
    event PrincipalImpairmentRecognized(
        uint256 indexed facilityId,
        uint256 amount,
        uint256 facilityImpairment,
        uint256 totalImpairment,
        uint256 backingAfter,
        bytes32 evidenceHash
    );
    /// @notice Governance released part of an evidence-backed conservative facility impairment.
    event PrincipalImpairmentReleased(
        uint256 indexed facilityId,
        uint256 amount,
        uint256 facilityImpairment,
        uint256 totalImpairment,
        bytes32 evidenceHash
    );
    /// @notice A principal write-down consumed the corresponding previously recognized impairment.
    event PrincipalImpairmentRealized(
        uint256 indexed facilityId, uint256 amount, uint256 facilityImpairment, uint256 totalImpairment
    );
    /// @notice The retained compatibility loss-absorber binding changed.
    event LossAbsorberSet(address indexed previousAbsorber, address indexed newAbsorber);
    /// @notice A funder supplied new reserve backing without minting claims.
    event Recapitalized(
        address indexed asset,
        address indexed funder,
        uint256 units,
        uint256 credited,
        uint256 backingAfter,
        uint256 deficitOutstanding
    );
    /// @notice A senior-exit junior draw was added to the historical prepayment ledger.
    event ExitPrepaymentRecorded(uint256 amount, uint256 outstanding);
    /// @notice A facility loss consumed part of the historical exit-prepayment ledger.
    event ExitPrepaymentConsumed(uint256 indexed facilityId, uint256 consumed, uint256 outstanding);
    /// @notice A custody loss consumed the surplus backing part of an exit prepayment.
    event ExitPrepaymentAbsorbedByCustody(uint256 indexed incidentId, uint256 consumed, uint256 outstanding);

    // ----------------------------- errors ----------------------------------

    /// @notice A value-moving call supplied a zero amount.
    error ReserveManager_ZeroAmount();
    /// @notice A required account or module address is zero.
    error ReserveManager_ZeroAddress();
    /// @notice An evidence-backed transition supplied the zero evidence hash.
    error ReserveManager_ZeroEvidenceHash();
    /// @notice No reserve asset has been listed, so no value path is open.
    error ReserveManager_NoAssetsListed();
    /// @notice The supplied token is not an admitted reserve asset.
    error ReserveManager_AssetNotListed(address asset);
    /// @notice The supplied token is already an admitted reserve asset.
    error ReserveManager_AssetAlreadyListed(address asset);
    /// @notice A candidate reserve asset has no deployed code.
    error ReserveManager_AssetNotContract(address asset);
    /// @notice A candidate reserve asset did not answer a full-word `balanceOf` probe.
    error ReserveManager_AssetNotERC20(address asset);
    /// @notice The registry is full.
    error ReserveManager_AssetLimitReached();
    /// @notice A candidate reserve asset declares more than eighteen decimals.
    error ReserveManager_UnsupportedDecimals(address asset, uint8 decimals);
    /// @notice The candidate's live `decimals()` differs from the value governance asserted.
    error ReserveManager_DecimalsMismatch(address asset, uint8 expected, uint8 observed);
    /// @notice The proposed mint fee exceeds the registry ceiling.
    error ReserveManager_MintFeeTooHigh(uint16 mintFeeBps);
    /// @notice A freeze call selected neither the mint nor the redeem flag.
    error ReserveManager_NoFreezeFlagsSelected();
    /// @notice Deposits of this asset are frozen.
    error ReserveManager_AssetMintFrozen(address asset);
    /// @notice Payouts of this asset are frozen, so it cannot fund a claim or a recorded draw.
    error ReserveManager_AssetRedeemFrozen(address asset);
    /// @notice The deposit would push this asset's recognized tally above its cap.
    error ReserveManager_AssetCapExceeded(address asset, uint256 cap, uint256 attemptedValue);
    /// @notice A cap cut would recognize more backing loss than governance approved.
    error ReserveManager_CapCutExceedsApproval(uint256 recognized, uint256 approvedMaxLoss);
    /// @notice The caller is not an authorised controller or credit depositor.
    error ReserveManager_NotDepositor(address caller);
    /// @notice A pull expected reserve units but received no value.
    error ReserveManager_NoValueReceived();
    /// @notice The token balance delta differed from the requested transfer.
    error ReserveManager_UnexpectedReceipt(address asset, uint256 expected, uint256 received);
    /// @notice An 18-decimal value cannot be represented exactly in that asset's native units.
    error ReserveManager_ValueNotExact(address asset, uint256 value);
    /// @notice Requested value exceeds one asset's recorded idle value.
    error ReserveManager_InsufficientIdleValue(uint256 requestedValue, uint256 idleValue);
    /// @notice Requested value exceeds the payable basket.
    error ReserveManager_InsufficientPayableValue(uint256 requestedValue, uint256 payableValue);
    /// @notice A release or deployment attempted to target the ReserveManager itself.
    error ReserveManager_SelfDeployment();
    /// @notice A basket release was entered with too little gas to bound every leg.
    error ReserveManager_InsufficientGasForBasket();
    /// @notice The caller holds no deferred leg in this asset.
    error ReserveManager_NoDeferredLeg(address asset);
    /// @notice A deferred payment exceeds recorded physical custody; returned tokens require their cure/recovery step.
    error ReserveManager_DeferredLegUnfunded(address asset, uint256 requested, uint256 custodied);
    /// @notice No un-ratified custody latch or no measured surplus is available to cure it.
    error ReserveManager_NoCustodyShortfall(address asset);
    /// @notice An adjudicated custody loss is unallocated, so protected out-doors are closed.
    error ReserveManager_IdleCustodyShortfall(uint256 latchedValue);
    /// @notice Requested principal reduction exceeds the facility's live deployed principal.
    error ReserveManager_InsufficientDeployedPrincipal(uint256 facilityId, uint256 requested, uint256 deployed);
    /// @notice A facility's credit acts must all use the asset bound on its first act.
    error ReserveManager_FacilityAssetMismatch(uint256 facilityId, address bound, address supplied);
    /// @notice A payment allocated more principal than the value actually received.
    error ReserveManager_PrincipalExceedsPayment(uint256 principal, uint256 paymentValue);
    /// @notice A proposed curator, vault, or absorber fails its binding contract.
    error ReserveManager_InvalidLossAbsorber(address absorber);
    /// @notice A proposed controller fails its module and reserve binding contract.
    error ReserveManager_InvalidLossController(address controller);
    /// @notice The proposed timelock does not expose a readable minimum delay at or above the floor.
    error ReserveManager_InvalidTimelock(address timelock);
    /// @notice A loss layer's reported burn differs from the observed USDfr supply reduction.
    error ReserveManager_LossAbsorberContractViolated(uint256 backingReduction, uint256 supplyBurned);
    /// @notice Reported cascade allocation does not reconcile to the recognized loss.
    error ReserveManager_LossAllocationMismatch(
        uint256 expectedSurplus, uint256 reportedSurplus, uint256 expectedAccounted, uint256 reportedAccounted
    );
    /// @notice The terminal live supply/backing deficit differs from the cascade calculation.
    error ReserveManager_PostLossDeficitMismatch(uint256 expectedDeficit, uint256 observedDeficit);
    /// @notice The caller lacks the reserve-administration authority required for the live loss path.
    error ReserveManager_ReserveLossCallerNotAdmin(address caller);
    /// @notice A reserve-loss allocation used an id outside the custody-event namespace.
    error ReserveManager_InvalidReserveLossIncident(uint256 incidentId);
    /// @notice A cascade was requested without a recognized supply reduction.
    error ReserveManager_NoRecognizedReserveLoss();
    /// @notice Finalization was attempted while recognized loss remains unallocated.
    error ReserveManager_RecognizedLossOutstanding(uint256 amount);
    /// @notice Finalization was attempted while that asset's custody latch is still live.
    error ReserveManager_LiveShortfallExists(uint256 nativeUnits);
    /// @notice Finalization was attempted while supply still exceeds backing.
    error ReserveManager_DeficitStillExists(uint256 recordedDeficit, uint256 observedDeficit);
    /// @notice Creation of new Guardian reserve-loss arms is disabled.
    error ReserveManager_GuardianArmsDisabled();
    /// @notice This asset already carries a live arm.
    error ReserveManager_ArmAlreadyActive(uint256 armId);
    /// @notice Historical recapitalization refusal, retained for ABI compatibility.
    /// @dev Retained for decoding earlier versions; current recapitalization does not emit it.
    error ReserveManager_RecapitalizationAdjudicationPending(address asset, uint256 armId);
    /// @notice A new withdrawal cannot draw or create a claim against a currency under review.
    error ReserveManager_AssetAdjudicationPending(address asset);
    /// @notice An arm-bound action requires a live arm on this asset.
    error ReserveManager_NoActiveArm();
    /// @notice The supplied arm id does not match this asset's live arm.
    error ReserveManager_ArmMismatch(uint256 expected, uint256 supplied);
    /// @notice The arm record names a different asset than the caller supplied.
    error ReserveManager_ArmAssetMismatch(uint256 armId, address expected, address supplied);
    /// @notice The arm is not in the state this transition requires.
    error ReserveManager_ArmStateInvalid(uint256 armId, ArmState state);
    /// @notice Ratification evidence does not match the Guardian's armed commitment.
    error ReserveManager_ArmEvidenceMismatch(bytes32 expected, bytes32 supplied);
    /// @notice The monotonic arm id space is exhausted.
    error ReserveManager_ArmIdExhausted();
    /// @notice Ratification found that the latched custody shortfall was already cured.
    error ReserveManager_ShortfallCured();
    /// @notice The latched custody loss exceeds governance's approved maximum.
    error ReserveManager_LossExceedsApproval(uint256 actualLoss, uint256 approvedMaxLoss);
    /// @notice No physically returned units are available for the supplied arm.
    error ReserveManager_NoRecoveredUnits(uint256 armId);
    /// @notice Finalization found returned units that have not yet been credited.
    error ReserveManager_RecoveredUnitsNotCredited(uint256 armId, uint256 nativeUnits);
    /// @notice Cancellation would release an interlock while a loss condition remains live.
    error ReserveManager_InterlockReleaseForbidden();
    /// @notice Loss-module rebinding is forbidden while an arm, shortfall, or deficit is live.
    error ReserveManager_ModuleRebindForbidden();
    /// @notice A conservative impairment would exceed the facility's remaining face principal.
    error ReserveManager_ImpairmentExceedsFace(uint256 facilityId, uint256 requested, uint256 remainingFace);
    /// @notice An impairment release exceeds the amount currently recognized for the facility.
    error ReserveManager_ImpairmentReleaseExceedsRecognized(uint256 facilityId, uint256 requested, uint256 recognized);
    /// @notice The caller is not the retained compatibility loss absorber.
    error ReserveManager_NotLossAbsorber(address caller);
    /// @notice Deficit resolution was requested without a recorded deficit.
    error ReserveManager_NoReserveDeficit();

    // --------------------- ADR-0038 price and record errors ----------------

    /// @notice No price oracle has been bound, so no price can be latched.
    error ReserveManager_PriceOracleUnset();
    /// @notice The proposed price oracle does not answer the price kind's threshold as one word.
    error ReserveManager_InvalidPriceOracle(address oracle);
    /// @notice The proposed price guards are outside their engineering ceilings.
    error ReserveManager_InvalidPriceGuards(uint64 maxAge, uint16 maxDeviationBps);
    /// @notice This asset carries no satisfied price attestation to latch.
    error ReserveManager_PriceNotAttested(address asset);
    /// @notice The attested price is zero or beyond the representability ceiling.
    error ReserveManager_PriceOutOfRange(address asset, uint256 price);
    /// @notice The attested observation is not strictly newer than the latched one.
    error ReserveManager_PriceNotNewer(address asset, uint64 attestedAsOf, uint64 latchedAsOf);
    /// @notice The push moves the price further than one update is permitted to move it.
    /// @dev IT REVERTS AND DOES NOT CLAMP. Clamping toward par would move the credit UP on
    ///      authority; clamping away from par would publish a number nobody signed. The refusal
    ///      leaves the previous value standing, which then ages out under the staleness bound and
    ///      closes minting in that asset. It NEVER falls back to par.
    error ReserveManager_PriceDeviationExceeded(address asset, uint256 latched, uint256 proposed, uint16 maxBps);
    /// @notice A zero mint floor was proposed. Refused: an unconfigured floor is not a floor.
    error ReserveManager_InvalidPriceFloor(address asset, uint256 floor);
    /// @notice The redemption asked for more value than the holder's record plus the payable basket.
    error ReserveManager_InsufficientRecordedValue(uint256 requestedValue, uint256 availableValue);
    /// @notice The caller holds no pending claim in this asset.
    error ReserveManager_NoPendingClaim(address asset);
    /// @notice A pending claim exists but no units of that asset are currently available to fund it.
    error ReserveManager_PendingClaimUnfunded(address asset, uint256 owedUnits);

    // ----------------------------- registry --------------------------------

    /// @notice Admits a reserve asset after asserting its declared decimals against the token.
    function addReserveAsset(
        address asset,
        uint8 expectedDecimals,
        uint256 cap,
        uint16 mintFeeBps,
        bytes32 admissionEvidenceHash
    ) external;

    /// @notice Sets one asset's 18-decimal exposure ceiling, recognizing any cut below the tally.
    function setReserveAssetCap(address asset, uint256 newCap, uint256 approvedMaxLoss, bytes32 evidenceHash)
        external;

    /// @notice Sets the per-asset mint fee the controller carves from the minter's USDfr credit.
    function setReserveAssetMintFee(address asset, uint16 mintFeeBps) external;

    /// @notice Guardian emergency freeze. May only set flags true.
    function freezeReserveAsset(address asset, bool mint, bool redeem) external;

    /// @notice Timelocked lift of a freeze. May only set flags false.
    function unfreezeReserveAsset(address asset, bool mint, bool redeem) external;

    /// @notice The listing order the basket allocation and the dust rule depend on.
    function reserveAssets() external view returns (address[] memory);
    /// @notice One registry row plus its derived payable and backing contributions.
    function assetRecord(address asset) external view returns (ReserveAssetView memory);
    /// @notice Every registry row, in listing order, as one reading of one state.
    function assetRecords() external view returns (ReserveAssetView[] memory);
    /// @notice Whether the token is an admitted reserve asset.
    function isListed(address asset) external view returns (bool);
    /// @notice Number of admitted reserve assets.
    function assetCount() external view returns (uint256);
    /// @notice Par value this asset can currently pay into a basket; zero when redeem-frozen.
    function payableValueOf(address asset) external view returns (uint256);
    /// @notice Whether this asset's custody-loss arm still awaits ratification.
    /// @dev A ratified arm remains open for recovery and finalization without this extra exit freeze.
    function assetAdjudicationPending(address asset) external view returns (bool);

    // ----------------------------- custody ---------------------------------

    /// @notice Pulls an exact amount of a listed reserve asset into recorded idle custody.
    function depositAsset(address asset, address from, uint256 amount) external returns (uint256 credited);

    /// @notice Pays `usdfrValue` of reserve value to `to` pro rata to every payable asset's tally.
    /// @dev A general basket withdrawal is refused while any currency awaits loss assessment.
    function releaseBasket(address to, uint256 usdfrValue)
        external
        returns (address[] memory legAssets, uint256[] memory legAmounts, uint256 valuePaid);

    /// @notice Pulls an exact amount of a listed reserve asset and credits `holder`'s deposit record.
    /// @dev The ADR-0038 deposit-recording form of `depositAsset`. `from` is the address the tokens
    ///      are pulled from, which on the mint path is the controller; `holder` is the depositor
    ///      whose record grows. They are separate parameters precisely because they differ there,
    ///      and crediting the record to `from` would credit every mint to the controller.
    /// @param asset The listed reserve asset.
    /// @param from The address the units are pulled from.
    /// @param holder The depositor whose record is credited.
    /// @param amount Native units.
    /// @return credited The 18-decimal value recognized.
    function depositAssetFor(address asset, address from, address holder, uint256 amount)
        external
        returns (uint256 credited);

    /// @notice Pays `usdfrValue` by drawing `to`'s OWN recorded assets first, then the basket.
    /// @dev THE RECORD CAP IS THE SECURITY PROPERTY. See this interface's own NatSpec.
    /// @param to The redeemer, and the owner of the deposit record drawn.
    /// @param usdfrValue The 18-decimal reserve value to settle.
    /// @return legAssets The registry, in listing order, at full length.
    /// @return legAmounts Native units DELIVERED (or escrowed as an undeliverable leg) per asset.
    /// @return valuePaid Total 18-decimal value settled: cash delivered plus promises escrowed.
    /// @dev THE RETURN SHAPE IS EXACTLY `releaseBasket`'s, deliberately, so the controller's
    ///      settlement assertions apply UNCHANGED: positional stability, no refused leg paid, and
    ///      the value equality recomputed from the controller's OWN cached scales. The promised
    ///      part is then `valuePaid - sum legAmounts_i * scale_i`, which the controller MEASURES for
    ///      itself rather than being told, and which is therefore the figure that survives a hostile
    ///      reserve. Its per-asset breakdown is on chain in `PendingClaimEscrowed` and readable
    ///      from `recordOf`.
    /// @dev During a pending review, every record used must be in an unreviewed, redeem-enabled
    ///      currency and cover the whole payout. No general basket or unit remainder is allowed.
    function releaseRecorded(address to, uint256 usdfrValue)
        external
        returns (address[] memory legAssets, uint256[] memory legAmounts, uint256 valuePaid);

    /// @notice Pulls units against a pending claim once the asset's units are back in the tally.
    function claimPendingUnits(address asset) external returns (uint256 amount);

    /// @notice Pulls a basket leg that could not be delivered when it was allocated.
    function claimDeferredLeg(address asset) external returns (uint256 amount);

    /// @notice One holder's position in one asset's deposit-record ledger, as ONE reading.
    /// @dev Returned together rather than as four views for the same reason `ReserveAssetView` is a
    ///      struct: enumerating the same quantity across several calls is how two views of one
    ///      number diverge. It also keeps the proxy inside EIP-170.
    /// @param holder The depositor.
    /// @param asset The listed asset.
    /// @return record Native units `holder` has deposited and not yet drawn down.
    /// @return pendingClaim Native units promised to `holder` but not yet funded.
    /// @return reservedUnits Native units of `asset` reserved across EVERY outstanding claim.
    /// @return claimValue Aggregate 18-decimal value of every outstanding claim, protocol-wide.
    function recordOf(address holder, address asset)
        external
        view
        returns (uint256 record, uint256 pendingClaim, uint256 reservedUnits, uint256 claimValue);

    // -------------------------- ADR-0038 price path ------------------------

    /// @notice Latches this asset's attested price into reserve storage. PERMISSIONLESS.
    /// @dev The ONLY way a price enters storage. There is deliberately no `setAssetPrice`; see the
    ///      implementation's NatSpec for why a direct setter may never be added.
    function syncAssetPrice(address asset) external;

    /// @notice Binds the price oracle and sets the global staleness and deviation guards.
    function setReservePriceGuards(address oracle, uint64 maxAge, uint16 maxDeviationBps) external;

    /// @notice Sets one asset's absolute mint floor. A zero floor is refused.
    function setReserveAssetPriceFloor(address asset, uint256 floor) external;

    /// @notice THE single mint-price predicate, with the raw record it was derived from.
    /// @dev One view rather than two, so a caller cannot compose a live/not-live answer from one
    ///      reading and a price from another. The controller consumes the first three returns; a
    ///      keeper and the frontend need the last three to show the price, its age and its floor.
    /// @param asset The listed asset.
    /// @return effective `min(price, 1e18)`, zero when not live. THE PAR CAP IS APPLIED HERE.
    /// @return live True when a mint may be credited against `effective`.
    /// @return reason 0 live, 1 never pushed, 2 stale, 3 below floor, 4 no floor configured.
    /// @return price The raw latched 18-decimal price, uncapped.
    /// @return asOf Its attested observation time.
    /// @return floor The asset's absolute mint floor.
    function mintPriceQuote(address asset)
        external
        view
        returns (uint256 effective, bool live, uint8 reason, uint256 price, uint64 asOf, uint256 floor);

    /// @notice The bound oracle and the global price guards, for monitoring and post-deploy checks.
    function reservePriceGuards() external view returns (address oracle, uint64 maxAge, uint16 maxDeviationBps);
    /// @notice Units of `asset` escrowed for `holder` by an undelivered basket leg.
    function deferredLegOf(address holder, address asset) external view returns (uint256);

    /// @notice Permissionlessly lowers one asset's tally to live custody and latches the shortfall.
    function reconcileIdleUnits(address asset) external returns (uint256 shortfall);

    /// @notice Permissionlessly credits measured returned units against an un-ratified latch only.
    function cureCustodyShortfall(address asset) external returns (uint256 credited);

    /// @notice Operator observation of one asset. No protocol path consumes it.
    function observeIdleUnits(address asset)
        external
        view
        returns (uint256 recorded, uint256 live, uint256 deferred, uint256 latched, uint256 liveShortfall);

    /// @notice Units of `asset` held above the amount recorded as idle custody or escrowed.
    function unrecordedUnits(address asset) external view returns (uint256);

    /// @notice Aggregate 18-decimal value of every latched, un-ratified custody shortfall.
    function idleCustodyShortfall() external view returns (uint256);
    /// @notice One asset's latched, un-ratified custody shortfall in 18-decimal value.
    function idleCustodyShortfallOf(address asset) external view returns (uint256);
    /// @notice Recorded backing net of every latched custody shortfall.
    function recognizedBackingValue() external view returns (uint256);
    /// @notice Whether an arm, recognized loss, deficit, or latched shortfall locks exits.
    function custodyLossUnabsorbed() external view returns (bool);

    /// @notice Pulls new reserve backing without minting USDfr claims.
    function recapitalize(address asset, uint256 amount) external returns (uint256 credited);

    // ---------------------------- cascade wiring ---------------------------

    /// @notice Wires the controller used for direct supply/backing and loss-burn checks.
    function setLossController(address controller) external;
    /// @notice Wires the retained compatibility absorber after verifying its reserve binding.
    function setLossAbsorber(address absorber) external;
    /// @notice Wires the two-layer custody cascade and the governance timing source.
    function setReserveLossModules(address curator, address vault, address timelock) external;

    /// @notice Guardian-only per-asset interlock created before an amount-bearing proposal.
    function armReserveLossFreeze(address asset, bytes32 evidenceHash)
        external
        returns (uint256 armId, uint256 incidentId);

    /// @notice Governance consumes an unratified arm; future Guardian arms stay disabled.
    function cancelAndDisable(address asset, uint256 expectedArmId, bytes32 evidenceHash) external;

    /// @notice Cancels a reconciled, unratified arm without releasing independent credit impairment.
    /// @dev Governance only. Requires nonzero evidence, exact asset and arm identity, no unsettled
    ///      custody loss, a bound controller and full physical custody of this asset. Disables
    ///      new guardian arms. A credit deficit alone does not prevent false-alarm resolution.
    function cancelUnratifiedArm(address asset, uint256 expectedArmId, bytes32 evidenceHash) external;

    /// @notice Governance kill switch for repeated Guardian arms.
    function setGuardianReserveLossArmsEnabled(bool enabled) external;

    /// @notice Governance ratifies and absorbs one asset's latched shortfall, bounded by approval.
    function ratifyAndOpen(address asset, uint256 expectedArmId, bytes32 evidenceHash, uint256 approvedMaxLoss)
        external
        returns (uint256 incidentId, uint256 actualLoss);

    /// @notice Credits physically returned units of the arm's own asset, capped by its write-down.
    function creditRecoveredIdleUnits(uint256 armId, bytes32 evidenceHash) external returns (uint256 credited);

    /// @notice Closes a ratified arm once the deficit is cured; future Guardian arms stay disabled.
    function finalizeAndDisable(address asset, uint256 expectedArmId, bytes32 evidenceHash) external;

    /// @notice Clears a cured reserve-deficit latch with supporting evidence.
    function resolveReserveDeficit(bytes32 evidenceHash) external;

    // ----------------------------- credit path -----------------------------

    /// @notice Converts recorded idle units of one asset into deployed facility principal.
    function recordDeployment(uint256 facilityId, address asset, address to, uint256 amount) external;
    /// @notice Adds retained origination-fee cash as facility principal without moving custody.
    function recordFeeCapitalization(uint256 facilityId, address asset, uint256 amount) external;

    /// @notice Capitalises accrued PIK interest into a facility's deployed principal. No cash moves.
    /// @dev CREDIT_ROLE, and in practice `WaterfallEngine.capitalizePik` alone, which carries the
    ///      rate, day-count, state, ceiling, concentration and surplus-neutrality bounds. See
    ///      `ReserveCreditLib.capitalizePik` for why there is no idle-value check.
    /// @param facilityId The facility.
    /// @param asset The facility's bound asset.
    /// @param amount 18-decimal value to capitalise, on the asset's scale grid.
    function recordPikCapitalization(uint256 facilityId, address asset, uint256 amount) external;
    /// @notice Atomically pulls exact units of the facility's bound asset and accounts principal.
    function recordPayment(uint256 facilityId, address asset, address payer, uint256 amount, uint256 principal)
        external
        returns (uint256 receivedValue);
    /// @notice Removes realized facility principal and consumes its corresponding impairment.
    function recordPrincipalWritedown(uint256 facilityId, uint256 amount) external;
    /// @notice Records an evidence-backed conservative mark without moving face principal.
    function recognizePrincipalImpairment(uint256 facilityId, uint256 amount, bytes32 evidenceHash) external;
    /// @notice Reverses a conservative mark, bounded by the amount previously recognized.
    function releasePrincipalImpairment(uint256 facilityId, uint256 amount, bytes32 evidenceHash) external;
    /// @notice The asset bound to a facility on its first credit-side act.
    function facilityAssetOf(uint256 facilityId) external view returns (address);

    // ----------------------------- value views -----------------------------

    /// @notice Payable idle custody in 18-decimal value: every listed, non-redeem-frozen tally.
    function idleReserve() external view returns (uint256);
    /// @notice Idle custody recognized as backing: the freeze-insensitive capped contribution sum.
    function totalIdleValue() external view returns (uint256);
    /// @notice One asset's recorded idle custody in its native units.
    function idleUnits(address asset) external view returns (uint256);
    /// @notice Known loss outside idle, and the part still awaiting ratification, in native units.
    function unappliedCustodyLossOf(address asset) external view returns (uint256 units, uint256 pendingUnits);
    /// @notice Aggregate 18-decimal deduction for known custody losses outside the idle tallies.
    function totalUnappliedCustodyLossValue() external view returns (uint256);
    /// @notice The arm's remaining known loss outside idle; restored only through that arm's recovery.
    function unappliedCustodyLossForArm(uint256 armId) external view returns (uint256);
    /// @notice Aggregate deployed facility principal before conservative impairments.
    function deployedPrincipal() external view returns (uint256);
    /// @notice Aggregate evidence-backed conservative principal impairment.
    function totalPrincipalImpairment() external view returns (uint256);
    /// @notice Evidence-backed conservative impairment recorded for one facility.
    function principalImpairmentOf(uint256 facilityId) external view returns (uint256);
    /// @notice Recognized idle contribution plus deployed principal, net of impairments.
    function totalBackingValue() external view returns (uint256);
    /// @notice Outstanding receivable face deployed to one facility.
    /// @dev Continuous accrual includes earned but unreceived cash and PIK interest.
    function deployedTo(uint256 facilityId) external view returns (uint256);
    /// @notice Converts native units of a listed asset into 18-decimal protocol value.
    function normalizeUnits(address asset, uint256 amount) external view returns (uint256);
    /// @notice Converts an exact 18-decimal value into a listed asset's native units.
    function denormalizeUnits(address asset, uint256 value) external view returns (uint256);

    // ---------------------------- register views ---------------------------

    /// @notice Controller used for supply, backing, and loss-burn verification.
    function lossController() external view returns (address);
    /// @notice Retained compatibility absorber bound to this reserve.
    function lossAbsorber() external view returns (address);
    /// @notice Ordered curator and vault cascade bindings plus the timing timelock.
    function reserveLossModules() external view returns (address curator, address vault, address timelock);
    /// @notice Latched portion of adjudicated custody losses not absorbed by any capital layer.
    function reserveDeficit() external view returns (uint256);
    /// @notice Current recognized backing reduction and pending cascade requirement.
    function recognizedReserveLoss()
        external
        view
        returns (uint256 backingReduction, uint256 surplusAbsorbed, uint256 supplyReductionRequired);
    /// @notice One asset's live arm identity, derived incident, evidence, state and the arm switch.
    function reserveLossArm(address asset)
        external
        view
        returns (uint256 armId, uint256 incidentId, bytes32 evidenceHash, ArmState state, bool armsEnabled);
    /// @notice Native recovery capacity created by write-downs under one arm.
    function reserveLossRecoveryCapacity(uint256 armId) external view returns (uint256 nativeUnits);
    /// @notice Number of arms in state `Armed` or `Ratified`.
    function openArmCount() external view returns (uint256);
    /// @notice Shared fail-closed interlock consumed by curator withdrawals and queue settlement.
    function reserveLossExitsLocked() external view returns (bool);
    /// @notice Backwards-compatible semantic alias used by CuratorModule.
    function curatorWithdrawalsLocked() external view returns (bool);
    /// @notice Historical junior prepayment still available for impairment release.
    function exitPrepaidAbsorption() external view returns (uint256);
    /// @notice Records a senior-exit junior draw in the compatibility prepayment ledger.
    function recordExitPrepayment(uint256 amount) external;
    /// @notice Consumes prepayment only against recognized impairment for a facility loss.
    function consumeExitPrepayment(uint256 facilityId, uint256 loss) external returns (uint256 used);
}
