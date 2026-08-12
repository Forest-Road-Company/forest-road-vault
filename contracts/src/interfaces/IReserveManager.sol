// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IReserveManager
/// @notice Mainnet-v1 treasury for canonical USDC and deployed facility principal.
/// @dev USD values use 18 decimals. USDC amounts use the token's native 6 decimals.
interface IReserveManager {
    /// @notice Canonical USDC was pulled into recorded idle custody.
    event USDCDeposited(address indexed from, uint256 requested, uint256 credited);
    /// @notice Canonical USDC was released from recorded idle custody.
    event USDCReleased(address indexed to, uint256 amount);
    /// @notice A permissionless observation compared recorded and live USDC custody.
    event IdleUSDCObserved(uint256 recorded, uint256 live, uint256 shortfall);
    /// @notice An adjudicated custody loss reduced recorded idle backing.
    event IdleUSDCWrittenDown(uint256 amount, uint256 remaining);
    /// @notice Returned USDC was credited against one arm's written-down recovery capacity.
    event RecoveredIdleUSDCCredited(
        uint256 indexed armId, uint256 nativeUnits, uint256 value, bytes32 indexed evidenceHash
    );
    /// @notice A custody loss reduced backing and fixed the supply reduction the cascade must absorb.
    event ReserveLossRecognized(
        uint256 indexed incidentId, uint256 backingReduction, uint256 surplusAbsorbed, uint256 supplyReductionRequired
    );
    /// @notice The complete surplus-to-senior allocation of one recognized custody loss.
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
    /// @notice The ordered custody-cascade and governance timing modules were wired.
    event ReserveLossModulesSet(
        address indexed curator, address indexed backstop, address indexed vault, address governor, address timelock
    );
    /// @notice A Guardian created a persistent reserve-loss interlock and evidence commitment.
    event ReserveLossArmed(uint256 indexed armId, uint256 indexed incidentId, bytes32 evidenceHash);
    /// @notice Governance cancelled an unused arm and disabled future Guardian arms.
    event ReserveLossArmCancelled(uint256 indexed armId, bytes32 indexed evidenceHash);
    /// @notice Governance closed the arm-bound incident and disabled future Guardian arms.
    event ReserveLossArmFinalized(uint256 indexed armId, uint256 indexed incidentId, bytes32 indexed evidenceHash);
    /// @notice Governance ratified and executed the current objective custody shortfall.
    event ReserveLossRatified(
        uint256 indexed armId,
        uint256 indexed incidentId,
        uint256 approvedMaxLoss,
        uint256 actualLoss,
        bytes32 evidenceHash
    );
    /// @notice Governance enabled or disabled creation of new Guardian reserve-loss arms.
    event GuardianReserveLossArmsEnabled(bool enabled);
    /// @notice A custody-loss incident entered the active register under its bound arm.
    event ReserveLossIncidentOpened(uint256 indexed incidentId, uint256 indexed armId, bytes32 evidenceHash);
    /// @notice The active custody-loss incident left the register.
    event ReserveLossIncidentClosed(uint256 indexed incidentId);
    /// @notice A cascade changed the latched unabsorbed reserve deficit.
    event ReserveDeficitUpdated(uint256 indexed incidentId, uint256 previousDeficit, uint256 currentDeficit);
    /// @notice Governance cleared a cured reserve-deficit latch with supporting evidence.
    event ReserveDeficitResolved(uint256 previousDeficit, bytes32 evidenceHash);
    /// @notice Idle USDC became deployed principal for a facility.
    event PrincipalDeployed(uint256 indexed facilityId, uint256 amount);
    /// @notice A retained origination fee became additional facility principal.
    event FeeCapitalized(uint256 indexed facilityId, uint256 amount);
    /// @notice A cash receipt increased idle custody and reduced the stated principal leg.
    event PaymentReceived(
        uint256 indexed facilityId, address indexed payer, uint256 usdcAmount, uint256 principalReturned
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
    /// @notice A funder supplied new canonical USDC backing without minting claims.
    event Recapitalized(
        address indexed funder, uint256 units, uint256 credited, uint256 backingAfter, uint256 deficitOutstanding
    );
    /// @notice A senior-exit junior draw was added to the historical prepayment ledger.
    event ExitPrepaymentRecorded(uint256 amount, uint256 outstanding);
    /// @notice A facility loss consumed part of the historical exit-prepayment ledger.
    event ExitPrepaymentConsumed(uint256 indexed facilityId, uint256 consumed, uint256 outstanding);

    /// @notice Requested USDC value exceeds recorded idle value.
    error ReserveManager_InsufficientIdleValue(uint256 requestedValue, uint256 idleValue);
    /// @notice Requested principal reduction exceeds the facility's live deployed principal.
    error ReserveManager_InsufficientDeployedPrincipal(uint256 facilityId, uint256 requested, uint256 deployed);
    /// @notice A value-moving call supplied a zero amount.
    error ReserveManager_ZeroAmount();
    /// @notice A required account or module address is zero.
    error ReserveManager_ZeroAddress();
    /// @notice The caller is not an authorised controller or credit depositor.
    error ReserveManager_NotDepositor(address caller);
    /// @notice A pull expected canonical USDC but received no value.
    error ReserveManager_NoValueReceived();
    /// @notice The token balance delta differed from the requested USDC transfer.
    error ReserveManager_UnexpectedUSDCReceipt(uint256 expected, uint256 received);
    /// @notice A legacy idle write-down exceeds recorded idle value.
    error ReserveManager_WriteDownExceedsIdle(uint256 amount, uint256 idle);
    /// @notice A USDC release or deployment attempted to target the ReserveManager itself.
    error ReserveManager_SelfDeployment();
    /// @notice An 18-decimal value cannot be represented exactly in native USDC units.
    error ReserveManager_ValueNotUSDCExact(uint256 value);
    /// @notice The configured custody token does not use canonical USDC's six decimals.
    error ReserveManager_InvalidUSDCDecimals(uint8 decimals);
    /// @notice A payment allocated more principal than the USDC value actually received.
    error ReserveManager_PrincipalExceedsPayment(uint256 principal, uint256 paymentValue);
    /// @notice A proposed curator, backstop, vault, or absorber fails its binding contract.
    error ReserveManager_InvalidLossAbsorber(address absorber);
    /// @notice A proposed controller fails its module and reserve binding contract.
    error ReserveManager_InvalidLossController(address controller);
    /// @notice A loss layer's reported burn differs from the observed USDfr supply reduction.
    error ReserveManager_LossAbsorberContractViolated(uint256 backingReduction, uint256 supplyBurned);
    /// @notice Reported cascade allocation does not reconcile to the recognized loss.
    error ReserveManager_LossAllocationMismatch(
        uint256 expectedSurplus, uint256 reportedSurplus, uint256 expectedAccounted, uint256 reportedAccounted
    );
    /// @notice The terminal live supply/backing deficit differs from the cascade calculation.
    error ReserveManager_PostLossDeficitMismatch(uint256 expectedDeficit, uint256 observedDeficit);
    /// @notice A custody incident id has already been consumed.
    error ReserveManager_IncidentAlreadyUsed(uint256 incidentId);
    /// @notice A new arm or incident cannot replace the currently active incident.
    error ReserveManager_IncidentAlreadyActive(uint256 incidentId);
    /// @notice A terminal action requires an active custody incident.
    error ReserveManager_NoActiveIncident();
    /// @notice The supplied custody incident does not match the active incident.
    error ReserveManager_IncidentMismatch(uint256 expected, uint256 supplied);
    /// @notice The caller lacks the reserve-administration authority required for the live loss path.
    error ReserveManager_ReserveLossCallerNotAdmin(address caller);
    /// @notice A reserve-loss allocation used an id outside the custody-event namespace.
    error ReserveManager_InvalidReserveLossIncident(uint256 incidentId);
    /// @notice A cascade was requested without a recognized supply reduction.
    error ReserveManager_NoRecognizedReserveLoss();
    /// @notice Finalization was attempted while recognized loss remains unallocated.
    error ReserveManager_RecognizedLossOutstanding(uint256 amount);
    /// @notice Finalization was attempted while live USDC custody remains short.
    error ReserveManager_LiveShortfallExists(uint256 nativeUnits);
    /// @notice Finalization was attempted while supply still exceeds backing.
    error ReserveManager_DeficitStillExists(uint256 recordedDeficit, uint256 observedDeficit);
    /// @notice Creation of new Guardian reserve-loss arms is disabled.
    error ReserveManager_GuardianArmsDisabled();
    /// @notice A new arm cannot replace the currently active arm.
    error ReserveManager_ArmAlreadyActive(uint256 armId);
    /// @notice An arm-bound action requires an active arm.
    error ReserveManager_NoActiveArm();
    /// @notice The supplied arm id does not match the active arm.
    error ReserveManager_ArmMismatch(uint256 expected, uint256 supplied);
    /// @notice Ratification evidence does not match the Guardian's armed commitment.
    error ReserveManager_ArmEvidenceMismatch(bytes32 expected, bytes32 supplied);
    /// @notice The monotonic arm id space is exhausted.
    error ReserveManager_ArmIdExhausted();
    /// @notice Ratification found that the objective custody shortfall was already cured.
    error ReserveManager_ShortfallCured();
    /// @notice The live custody loss exceeds governance's approved maximum.
    error ReserveManager_LossExceedsApproval(uint256 actualLoss, uint256 approvedMaxLoss);
    /// @notice No physically returned USDC is available for the supplied arm.
    error ReserveManager_NoRecoveredUSDC(uint256 armId);
    /// @notice Finalization found returned USDC that has not yet been credited.
    error ReserveManager_RecoveredUSDCNotCredited(uint256 armId, uint256 nativeUnits);
    /// @notice The superseded arbitrary idle-write-down entry is permanently disabled.
    error ReserveManager_LegacyPathDisabled();
    /// @notice Cancellation would release an interlock while a loss condition remains live.
    error ReserveManager_InterlockReleaseForbidden();
    /// @notice Loss-module rebinding is forbidden while an arm, incident, shortfall, or deficit is live.
    error ReserveManager_ModuleRebindForbidden();
    /// @notice The proposed governor and timelock do not expose one coherent live timing path.
    error ReserveManager_InvalidGovernanceTiming(address governor, address timelock);
    /// @notice An evidence-backed transition supplied the zero evidence hash.
    error ReserveManager_ZeroEvidenceHash();
    /// @notice A conservative impairment would exceed the facility's remaining face principal.
    error ReserveManager_ImpairmentExceedsFace(uint256 facilityId, uint256 requested, uint256 remainingFace);
    /// @notice An impairment release exceeds the amount currently recognized for the facility.
    error ReserveManager_ImpairmentReleaseExceedsRecognized(uint256 facilityId, uint256 requested, uint256 recognized);
    /// @notice The caller is not the retained compatibility loss absorber.
    error ReserveManager_NotLossAbsorber(address caller);
    /// @notice Recorded idle USDC exceeds live custody, so a protected out-door is closed.
    error ReserveManager_IdleCustodyShortfall(uint256 recordedUnits, uint256 liveUnits);
    /// @notice A legacy incident nonce is zero or enters the reserved custody namespace.
    error ReserveManager_InvalidIncidentNonce(uint256 incidentNonce);
    /// @notice Deficit resolution was requested without a recorded deficit.
    error ReserveManager_NoReserveDeficit();
    /// @notice An incident close requires its recorded deficit to be resolved first.
    error ReserveManager_DeficitResolutionRequired(uint256 recordedDeficit);

    /// @notice Pulls exact canonical USDC from `from` into recorded idle custody.
    function depositUSDC(address from, uint256 amount) external returns (uint256 credited);
    /// @notice Releases recorded idle USDC through the controller-only redemption path.
    function releaseUSDC(address to, uint256 amount) external;

    /// @notice Permissionlessly checkpoints the objective live-vs-recorded custody shortfall.
    /// @dev Observation never changes backing and never moves junior or senior capital.
    /// @return shortfall Native six-decimal USDC units missing from custody.
    function reconcileIdleUSDC() external returns (uint256 shortfall);

    /// @notice Permissionless live-vs-recorded custody observation; never changes accounting.
    function observeIdleUSDC() external view returns (uint256 recorded, uint256 live, uint256 shortfall);

    /// @notice Native USDC units by which recorded idle custody exceeds the live token balance.
    function idleCustodyShortfall() external view returns (uint256);
    /// @notice Recorded backing net of any physically observable idle-custody shortfall.
    function recognizedBackingValue() external view returns (uint256);
    /// @notice Whether an arm, incident, recognized loss, deficit, or live shortfall locks exits.
    function custodyLossUnabsorbed() external view returns (bool);

    /// @notice Wires the controller used for direct supply/backing and loss-burn checks.
    function setLossController(address controller) external;
    /// @notice Wires the retained compatibility absorber after verifying its reserve binding.
    function setLossAbsorber(address absorber) external;

    /// @notice Legacy incident controls retained as non-credit compatibility surfaces while
    ///         new custody accounting uses the arm-bound ratification path.
    function openReserveLossIncident(uint256 incidentNonce, bytes32 evidenceHash)
        external
        returns (uint256 incidentId);
    /// @notice Closes the exact active legacy incident once no deficit remains.
    function closeReserveLossIncident(uint256 incidentId) external;
    /// @notice Clears a cured legacy reserve-deficit latch with supporting evidence.
    function resolveReserveDeficit(bytes32 evidenceHash) external;
    /// @notice Canonical USDC held above the amount recorded as idle custody.
    function unrecordedUSDC() external view returns (uint256);

    /// @notice Wires the ordered custody cascade and its live governance timing sources.
    function setReserveLossModules(address curator, address backstop, address vault, address governor, address timelock)
        external;

    /// @notice Guardian-only persistent interlock created before an amount-bearing proposal.
    /// @return armId Monotonic internal id consumed only by an explicit governance terminal action.
    /// @return incidentId Structurally bound upper-half custody event id.
    function armReserveLossFreeze(bytes32 evidenceHash) external returns (uint256 armId, uint256 incidentId);

    /// @notice Governance consumes an unused arm only when the objective shortfall is zero and
    ///         no adjudicated loss, incident or deficit exists; future Guardian arms stay disabled.
    function cancelAndDisable(uint256 expectedArmId, bytes32 evidenceHash) external;

    /// @notice Governance kill switch for repeated Guardian arms.
    function setGuardianReserveLossArmsEnabled(bool enabled) external;

    /// @notice Governance ratifies and atomically absorbs the live objective shortfall, bounded
    ///         by the amount approved in the proposal. Every tranche under an arm reuses its id
    ///         and must supply the Guardian's exact armed evidence commitment.
    function ratifyAndOpen(uint256 expectedArmId, bytes32 evidenceHash, uint256 approvedMaxLoss)
        external
        returns (uint256 incidentId, uint256 actualLoss);

    /// @notice Credits physically returned canonical USDC without minting USDfr, capped by the
    ///         amount previously written down under `armId`. May execute after incident closure.
    function creditRecoveredIdleUSDC(uint256 armId, bytes32 evidenceHash) external returns (uint256 credited);

    /// @notice Atomically resolves a cured deficit, closes the arm-bound incident and disables
    ///         future Guardian arms. It cannot release a shortfall or uncredited returned USDC.
    function finalizeAndDisable(uint256 expectedArmId, bytes32 evidenceHash) external;

    /// @notice Pulls new canonical USDC backing without minting USDfr claims.
    function recapitalize(uint256 amount) external returns (uint256 credited);

    /// @notice Controller used for supply, backing, and loss-burn verification.
    function lossController() external view returns (address);
    /// @notice Ordered curator, backstop, vault, governor, and timelock bindings.
    function reserveLossModules()
        external
        view
        returns (address curator, address backstop, address vault, address governor, address timelock);
    /// @notice Active custody incident id and its evidence commitment.
    function activeReserveLossIncident() external view returns (uint256 incidentId, bytes32 evidenceHash);
    /// @notice Whether a custody incident id has already entered the durable register.
    function reserveLossIncidentUsed(uint256 incidentId) external view returns (bool);
    /// @notice Latched portion of adjudicated custody losses not absorbed by any capital layer.
    function reserveDeficit() external view returns (uint256);
    /// @notice Current recognized backing reduction and pending cascade requirement.
    function recognizedReserveLoss()
        external
        view
        returns (uint256 backingReduction, uint256 surplusAbsorbed, uint256 supplyReductionRequired);
    /// @notice Active arm identity, derived incident, armed evidence, and future-arm switch.
    function reserveLossArm()
        external
        view
        returns (uint256 armId, uint256 incidentId, bytes32 evidenceHash, bool armsEnabled);
    /// @notice Native USDC recovery capacity created by write-downs under one arm.
    function reserveLossRecoveryCapacity(uint256 armId) external view returns (uint256 nativeUnits);
    /// @notice Retained compatibility absorber bound to this reserve.
    function lossAbsorber() external view returns (address);
    /// @notice Historical junior prepayment still available for impairment release.
    function exitPrepaidAbsorption() external view returns (uint256);
    /// @notice Records a senior-exit junior draw in the compatibility prepayment ledger.
    function recordExitPrepayment(uint256 amount) external;
    /// @notice Consumes prepayment only against recognized impairment for a facility loss.
    function consumeExitPrepayment(uint256 facilityId, uint256 loss) external returns (uint256 used);

    /// @notice Shared fail-closed interlock consumed by curator withdrawals and queue settlement.
    function reserveLossExitsLocked() external view returns (bool);

    /// @notice Backwards-compatible semantic alias used by CuratorModule.
    function curatorWithdrawalsLocked() external view returns (bool);

    /// @notice Converts exact recorded idle USDC into deployed facility principal.
    function recordDeployment(uint256 facilityId, address to, uint256 usdcAmount) external;
    /// @notice Adds retained origination-fee cash as facility principal without moving custody.
    function recordFeeCapitalization(uint256 facilityId, uint256 amount) external;

    /// @notice Atomically pulls exact USDC and accounts the principal leg.
    function recordPayment(uint256 facilityId, address payer, uint256 usdcAmount, uint256 principal)
        external
        returns (uint256 receivedValue);

    /// @notice Removes realized facility principal and consumes its corresponding impairment.
    function recordPrincipalWritedown(uint256 facilityId, uint256 amount) external;

    /// @notice Records an evidence-backed conservative mark without moving face principal or
    ///         allocating the loss between capital layers.
    function recognizePrincipalImpairment(uint256 facilityId, uint256 amount, bytes32 evidenceHash) external;

    /// @notice Reverses a conservative mark, bounded by the amount previously recognized.
    function releasePrincipalImpairment(uint256 facilityId, uint256 amount, bytes32 evidenceHash) external;

    /// @notice Recorded idle custody expressed as 18-decimal USDfr value.
    function idleReserve() external view returns (uint256);
    /// @notice Recorded idle custody in native six-decimal USDC units.
    function idleUSDC() external view returns (uint256);
    /// @notice Aggregate deployed facility principal before conservative impairments.
    function deployedPrincipal() external view returns (uint256);
    /// @notice Aggregate evidence-backed conservative principal impairment.
    function totalPrincipalImpairment() external view returns (uint256);
    /// @notice Evidence-backed conservative impairment recorded for one facility.
    function principalImpairmentOf(uint256 facilityId) external view returns (uint256);
    /// @notice Recorded idle plus deployed principal, net of conservative impairments.
    function totalBackingValue() external view returns (uint256);
    /// @notice Remaining face principal deployed to one facility.
    function deployedTo(uint256 facilityId) external view returns (uint256);
    /// @notice Canonical six-decimal USDC token held by the reserve.
    function usdc() external view returns (address);
    /// @notice Converts native six-decimal USDC units to 18-decimal protocol value.
    function normalizeUSDC(uint256 amount) external pure returns (uint256);
    /// @notice Converts exact 18-decimal protocol value to native USDC units.
    function denormalizeUSDC(uint256 value) external pure returns (uint256);
}
