// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ReferralRegistry
/// @notice A standalone, permissionless register of who referred whom. It records two facts and
///         nothing else: that an address has opted in as a referrer, and that another address has
///         permanently bound itself to one referrer. It computes no reward, holds no token, and
///         has no import from and no call into any Forest Road protocol contract.
///
/// @dev **WHY THIS CONTRACT IS DELIBERATELY DUMB.** Attribution is computed OFF chain by joining
///      the events emitted here to the protocol's own points accounting, which already measures
///      time-weighted participation per wallet. Rewards are paid on referred points-days, never on
///      referral headcount, because headcount is trivially farmable once becoming a referrer is
///      open to anyone, while points-days require real balance held over real time. Nothing here
///      should ever try to compute, accrue or pay a reward; if that need arises it belongs in a
///      separate contract reading these events, not in this one.
///
///      **WHY THERE IS NO ADMIN GATE ON BECOMING A REFERRER.** `registerAsReferrer` is the on-chain
///      half of the app's "generate my referral link" button, sent by the user from their own
///      wallet. A referral link therefore carries the referrer's own ADDRESS: there is no name to
///      choose, so there is nothing to collide and nothing to squat.
///
///      **WHY ALIASES ARE ADMIN-ONLY AND NEVER REPOINTABLE.** An alias is a memorable code
///      (`?ref=alice`) so a KOL's link need not be an address. It is admin-assigned precisely so
///      brand names cannot be squatted. MANY aliases may point at ONE referrer, which is how a KOL
///      gets a separate code per channel while payout still aggregates to one person. An alias,
///      once assigned, can NEVER be pointed at a different referrer, because everyone already bound
///      through it would be retroactively re-attributed. `assignAlias` is one-shot per code:
///      re-assignment is refused even to the same referrer, so the alias-to-referrer edge is
///      immutable by construction rather than by a conditional an auditor has to reason about.
///
///      **WHY DEACTIVATION IS FORWARD-ONLY.** `setAliasActive` and `setReferrerActive` stop NEW
///      bindings and leave every existing binding intact and readable. Historic attribution is
///      never rewritten.
///
///      **WHY THERE IS NO ADMIN CORRECTION PATH FOR A MISTAKEN BINDING.** The owner asked that
///      this be decided explicitly, and the decision is NO, for three reasons. First, a binding is
///      the referee's own signed transaction naming a referrer, so there is no protocol-side
///      ambiguity about what was agreed; the only "mistake" available is a user who changed their
///      mind, which is not a thing an administrator should be able to ratify silently. Second, the
///      reward computation already lives off chain, so a genuine correction can be made in that
///      join with a full evidence trail, which is more than a single on-chain event could ever
///      carry. Third, and decisively: an admin rewrite would hand the administrator the power to
///      re-attribute another party's referral economics after the fact, which is exactly the power
///      the never-repoint rule above exists to deny. Adding a correction path would reintroduce
///      through the front door the capability that rule closes at the back. Because this contract
///      is not upgradeable and custodies nothing, the escape hatch if one is ever genuinely needed
///      is to deploy a second registry and index both.
///
///      **WHAT THIS CONTRACT DOES NOT TRY TO DO.** It blocks self-referral and nothing else. It
///      does not attempt to detect sybils, mutual referral (A binds to B while B binds to A), or a
///      single person operating several wallets. Those are off-chain policy questions and are
///      answered where the reward is computed; any on-chain heuristic would be both incomplete and
///      permanent. Referral is one hop deep: a binding never chains, so no cycle can recurse here.
///
///      **NOT UPGRADEABLE, DELIBERATELY.** It custodies nothing, so the blast radius of a wrong
///      deployment is a wrong deployment: abandon it, deploy a second registry, and index both.
///      That is strictly safer than carrying a proxy whose admin could rewrite the attribution
///      record.
///
///      Nothing in this contract characterizes any Forest Road instrument.
contract ReferralRegistry is AccessControl {
    // -- roles ------------------------------------------------------------

    /// @notice Role permitted to assign aliases and to deactivate aliases and referrers.
    /// @dev Held by the administrator named by Forest Road at construction, never by whatever key
    ///      happened to broadcast the deployment (CLAUDE.md section 0.1, the 2026-09-07 amendment).
    bytes32 public constant REFERRAL_ADMIN_ROLE = keccak256("REFERRAL_ADMIN_ROLE");

    // -- storage ----------------------------------------------------------

    /// @notice One referrer's opt-in record.
    /// @param registered True once `registerAsReferrer` has succeeded. Never reverts to false.
    /// @param active Whether the referrer may receive NEW bindings.
    /// @param registeredAt Block timestamp of the opt-in.
    /// @param refereeCount Number of addresses bound to this referrer, for cheap display.
    struct ReferrerRecord {
        bool registered;
        bool active;
        uint64 registeredAt;
        uint64 refereeCount;
    }

    /// @notice One referee's permanent binding.
    /// @param referrer The referrer this address is bound to; zero when unbound.
    /// @param boundAt Block timestamp of the binding.
    /// @param aliasUsed The alias the binding came through, or zero when bound by address.
    struct BindingRecord {
        address referrer;
        uint64 boundAt;
        bytes32 aliasUsed;
    }

    /// @notice One alias code.
    /// @param referrer The registered referrer this code resolves to; zero when unassigned.
    /// @param active Whether the code may be used for NEW bindings.
    /// @param handle Human-readable label recorded for display without an indexer.
    struct AliasRecord {
        address referrer;
        bool active;
        string handle;
    }

    /// @dev Referrer opt-in records, by referrer address.
    mapping(address referrer => ReferrerRecord record) private _referrers;

    /// @dev Permanent bindings, by referee address.
    mapping(address referee => BindingRecord record) private _bindings;

    /// @dev Alias codes, by code.
    mapping(bytes32 aliasCode => AliasRecord record) private _aliases;

    // -- events -----------------------------------------------------------

    /// @notice Emitted once when an address opts in as a referrer.
    /// @param referrer The address that opted in; this is what its referral link carries.
    /// @param registeredAt Block timestamp of the opt-in.
    event ReferrerRegistered(address indexed referrer, uint64 registeredAt);

    /// @notice Emitted once when a referee permanently binds to a referrer.
    /// @param referee The bound address.
    /// @param referrer The referrer credited from this point on.
    /// @param aliasUsed The alias the binding came through, or zero when bound by address. Indexed
    ///        so per-channel attribution can be reconstructed from logs alone.
    /// @param boundAt Block timestamp of the binding.
    event ReferralBound(address indexed referee, address indexed referrer, bytes32 indexed aliasUsed, uint64 boundAt);

    /// @notice Emitted once when an alias code is assigned. An alias is never reassigned, so this
    ///         event is the complete and final record of what the code resolves to.
    /// @param aliasCode The code.
    /// @param referrer The registered referrer it resolves to, permanently.
    /// @param handle Human-readable label supplied by the administrator.
    event AliasAssigned(bytes32 indexed aliasCode, address indexed referrer, string handle);

    /// @notice Emitted when an alias code's ability to take NEW bindings changes. Existing
    ///         bindings made through the code are unaffected.
    /// @param aliasCode The code.
    /// @param active The new state.
    event AliasActiveSet(bytes32 indexed aliasCode, bool active);

    /// @notice Emitted when a referrer's ability to take NEW bindings changes. Existing bindings
    ///         to the referrer are unaffected.
    /// @param referrer The referrer.
    /// @param active The new state.
    event ReferrerActiveSet(address indexed referrer, bool active);

    // -- errors -----------------------------------------------------------

    /// @notice Thrown when the administrator named at construction is the zero address.
    error ReferralRegistry_ZeroAddress();

    /// @notice Thrown when an address that has already opted in calls `registerAsReferrer` again.
    /// @param referrer The address that is already registered.
    error ReferralRegistry_AlreadyRegistered(address referrer);

    /// @notice Thrown when an address that is already bound tries to bind again. Bindings are
    ///         permanent; this is the guard that makes them so.
    /// @param referee The address that is already bound.
    /// @param referrer The referrer it is bound to.
    error ReferralRegistry_AlreadyBound(address referee, address referrer);

    /// @notice Thrown when an address tries to bind to itself.
    /// @param account The caller.
    error ReferralRegistry_SelfReferral(address account);

    /// @notice Thrown when the named referrer has never opted in.
    /// @param referrer The address that is not a registered referrer.
    error ReferralRegistry_ReferrerNotRegistered(address referrer);

    /// @notice Thrown when the named referrer is registered but deactivated for NEW bindings.
    /// @param referrer The deactivated referrer.
    error ReferralRegistry_ReferrerNotActive(address referrer);

    /// @notice Thrown when the zero alias is supplied. Zero is reserved to mean "bound by address".
    error ReferralRegistry_ZeroAlias();

    /// @notice Thrown when assigning an alias that has already been assigned. Assignment is
    ///         one-shot per code, so an alias can never be repointed and past bindings through it
    ///         can never be retroactively re-attributed.
    /// @param aliasCode The code.
    /// @param existingReferrer The referrer it already resolves to, permanently.
    error ReferralRegistry_AliasAlreadyAssigned(bytes32 aliasCode, address existingReferrer);

    /// @notice Thrown when an alias that was never assigned is used or administered.
    /// @param aliasCode The code.
    error ReferralRegistry_AliasNotAssigned(bytes32 aliasCode);

    /// @notice Thrown when binding through an alias that has been deactivated. Bindings already
    ///         made through it remain intact and readable.
    /// @param aliasCode The code.
    error ReferralRegistry_AliasNotActive(bytes32 aliasCode);

    // -- construction -----------------------------------------------------

    /// @notice Deploys the registry with a Forest-Road-named administrator.
    /// @dev The broadcasting key is granted NOTHING. CLAUDE.md section 0.1 requires the administrator to
    ///      be named by Forest Road rather than defaulted to whatever key is in the local
    ///      environment, so a raw developer key cannot end up holding administrative control of a
    ///      live contract. The deployment script enforces the same rule before broadcasting.
    /// @param admin The administrator, granted both `DEFAULT_ADMIN_ROLE` and `REFERRAL_ADMIN_ROLE`.
    constructor(address admin) {
        if (admin == address(0)) revert ReferralRegistry_ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REFERRAL_ADMIN_ROLE, admin);
    }

    // -- permissionless: becoming a referrer ------------------------------

    /// @notice Opts the caller in as a referrer. This is the on-chain "generate my referral link"
    ///         action: permissionless, callable by anyone, exactly once, from the caller's own
    ///         wallet. The link that follows carries the caller's ADDRESS.
    /// @dev There is deliberately no admin gate and no name to choose, so there is no collision
    ///      and nothing to squat. Registration cannot be undone; `setReferrerActive(false)` stops
    ///      new bindings without erasing the record.
    function registerAsReferrer() external {
        ReferrerRecord storage r = _referrers[msg.sender];
        if (r.registered) revert ReferralRegistry_AlreadyRegistered(msg.sender);

        uint64 nowTs = uint64(block.timestamp);
        r.registered = true;
        r.active = true;
        r.registeredAt = nowTs;

        emit ReferrerRegistered(msg.sender, nowTs);
    }

    // -- permissionless: binding ------------------------------------------

    /// @notice Permanently binds the caller to `referrer`, by address.
    /// @dev Callable once per address, ever. Reverts if the caller is already bound, if the caller
    ///      is the referrer, if the referrer never registered, or if the referrer is deactivated.
    /// @param referrer The registered, active referrer to credit.
    function bindReferral(address referrer) external {
        _bind(msg.sender, referrer, bytes32(0));
    }

    /// @notice Permanently binds the caller to whichever referrer `alias_` resolves to.
    /// @dev The alias is recorded on the binding and indexed in `ReferralBound`, so a KOL running
    ///      one code per channel can attribute per channel while payout aggregates to one address.
    ///      Reverts if the alias was never assigned or has been deactivated, and then applies every
    ///      check `bindReferral` applies.
    /// @param alias_ The alias code, e.g. `bytes32("alice")`.
    function bindReferralByAlias(bytes32 alias_) external {
        if (alias_ == bytes32(0)) revert ReferralRegistry_ZeroAlias();

        AliasRecord storage a = _aliases[alias_];
        if (a.referrer == address(0)) revert ReferralRegistry_AliasNotAssigned(alias_);
        if (!a.active) revert ReferralRegistry_AliasNotActive(alias_);

        _bind(msg.sender, a.referrer, alias_);
    }

    // -- administration ---------------------------------------------------

    /// @notice Assigns a memorable code to a registered referrer, permanently.
    /// @dev Admin-only so brand names cannot be squatted. MANY aliases may point at ONE referrer.
    ///      An alias is assigned exactly once and can never be reassigned, not even back to the
    ///      same referrer, because a repoint would retroactively re-attribute everyone already
    ///      bound through it. To change the label, assign a new code.
    /// @param alias_ The code; must be non-zero, since zero means "bound by address".
    /// @param referrer The registered referrer the code resolves to.
    /// @param handle Human-readable label, recorded for display without an indexer.
    function assignAlias(bytes32 alias_, address referrer, string calldata handle)
        external
        onlyRole(REFERRAL_ADMIN_ROLE)
    {
        if (alias_ == bytes32(0)) revert ReferralRegistry_ZeroAlias();

        AliasRecord storage a = _aliases[alias_];
        if (a.referrer != address(0)) revert ReferralRegistry_AliasAlreadyAssigned(alias_, a.referrer);
        if (!_referrers[referrer].registered) revert ReferralRegistry_ReferrerNotRegistered(referrer);

        a.referrer = referrer;
        a.active = true;
        a.handle = handle;

        emit AliasAssigned(alias_, referrer, handle);
    }

    /// @notice Enables or disables an alias for NEW bindings.
    /// @dev Deactivation is forward-only: bindings already made through the code keep reading
    ///      correctly, including the alias they came through. Historic attribution is never
    ///      rewritten.
    /// @param alias_ The assigned code.
    /// @param active The new state.
    function setAliasActive(bytes32 alias_, bool active) external onlyRole(REFERRAL_ADMIN_ROLE) {
        AliasRecord storage a = _aliases[alias_];
        if (a.referrer == address(0)) revert ReferralRegistry_AliasNotAssigned(alias_);

        a.active = active;

        emit AliasActiveSet(alias_, active);
    }

    /// @notice Enables or disables a referrer for NEW bindings, by address and through every alias
    ///         that resolves to them.
    /// @dev Deactivation is forward-only: existing bindings keep reading correctly.
    /// @param referrer The registered referrer.
    /// @param active The new state.
    function setReferrerActive(address referrer, bool active) external onlyRole(REFERRAL_ADMIN_ROLE) {
        ReferrerRecord storage r = _referrers[referrer];
        if (!r.registered) revert ReferralRegistry_ReferrerNotRegistered(referrer);

        r.active = active;

        emit ReferrerActiveSet(referrer, active);
    }

    // -- views ------------------------------------------------------------

    /// @notice Whether an address has ever opted in as a referrer.
    /// @param referrer The address to check.
    /// @return registered True once the address has registered; never reverts to false.
    function isReferrer(address referrer) external view returns (bool registered) {
        return _referrers[referrer].registered;
    }

    /// @notice Whether an address may receive NEW bindings right now.
    /// @param referrer The address to check.
    /// @return active True when registered and not deactivated.
    function isActiveReferrer(address referrer) external view returns (bool active) {
        ReferrerRecord storage r = _referrers[referrer];
        return r.registered && r.active;
    }

    /// @notice The full referrer record.
    /// @param referrer The address to read.
    /// @return registered Whether the address has opted in.
    /// @return active Whether it may receive new bindings.
    /// @return registeredAt Block timestamp of the opt-in, or zero if never registered.
    /// @return refereeCount Number of addresses bound to it.
    function referrerInfo(address referrer)
        external
        view
        returns (bool registered, bool active, uint64 registeredAt, uint64 refereeCount)
    {
        ReferrerRecord storage r = _referrers[referrer];
        return (r.registered, r.active, r.registeredAt, r.refereeCount);
    }

    /// @notice The referrer an address is bound to.
    /// @param referee The address to read.
    /// @return referrer The bound referrer, or the zero address when unbound.
    function referrerOf(address referee) external view returns (address referrer) {
        return _bindings[referee].referrer;
    }

    /// @notice The full binding record.
    /// @param referee The address to read.
    /// @return referrer The bound referrer, or the zero address when unbound.
    /// @return boundAt Block timestamp of the binding, or zero when unbound.
    /// @return aliasUsed The alias the binding came through, or zero when bound by address.
    function bindingOf(address referee) external view returns (address referrer, uint64 boundAt, bytes32 aliasUsed) {
        BindingRecord storage b = _bindings[referee];
        return (b.referrer, b.boundAt, b.aliasUsed);
    }

    /// @notice Whether an address has already bound and can therefore never bind again.
    /// @param referee The address to check.
    /// @return bound True once bound.
    function isBound(address referee) external view returns (bool bound) {
        return _bindings[referee].referrer != address(0);
    }

    /// @notice How many addresses are bound to a referrer, for cheap display.
    /// @dev Headcount is display only. Rewards are computed off chain on referred points-days,
    ///      because headcount is trivially farmable and points-days are not.
    /// @param referrer The referrer to read.
    /// @return count The number of bound referees.
    function refereeCountOf(address referrer) external view returns (uint64 count) {
        return _referrers[referrer].refereeCount;
    }

    /// @notice The referrer an alias resolves to.
    /// @param alias_ The code.
    /// @return referrer The referrer, or the zero address when the code was never assigned.
    function resolveAlias(bytes32 alias_) external view returns (address referrer) {
        return _aliases[alias_].referrer;
    }

    /// @notice Whether an alias may be used for NEW bindings.
    /// @param alias_ The code.
    /// @return active True only when assigned and not deactivated.
    function isAliasActive(bytes32 alias_) external view returns (bool active) {
        AliasRecord storage a = _aliases[alias_];
        return a.referrer != address(0) && a.active;
    }

    /// @notice The full alias record.
    /// @param alias_ The code.
    /// @return referrer The referrer it resolves to, or zero when unassigned.
    /// @return active Whether it may be used for new bindings.
    /// @return handle The administrator-supplied label.
    function aliasInfo(bytes32 alias_) external view returns (address referrer, bool active, string memory handle) {
        AliasRecord storage a = _aliases[alias_];
        return (a.referrer, a.active, a.handle);
    }

    // -- internals --------------------------------------------------------

    /// @notice The single binding path, shared by `bindReferral` and `bindReferralByAlias`.
    /// @dev Check order is deliberate and is asserted in the tests, so a given failing call always
    ///      produces the same diagnosis. Already-bound comes first because it is a fact about the
    ///      caller and makes the permanence of a binding the loudest answer. Self-referral comes
    ///      next so that an unregistered caller pointing at itself is told it is self-referral
    ///      rather than told it is not a referrer, which would read as an invitation to register
    ///      first and try again. Registration then activity follow, narrowest last.
    /// @param referee The binding address.
    /// @param referrer The referrer to credit.
    /// @param aliasUsed The alias the binding came through, or zero when bound by address.
    function _bind(address referee, address referrer, bytes32 aliasUsed) private {
        BindingRecord storage b = _bindings[referee];
        if (b.referrer != address(0)) revert ReferralRegistry_AlreadyBound(referee, b.referrer);
        if (referrer == referee) revert ReferralRegistry_SelfReferral(referee);

        ReferrerRecord storage r = _referrers[referrer];
        if (!r.registered) revert ReferralRegistry_ReferrerNotRegistered(referrer);
        if (!r.active) revert ReferralRegistry_ReferrerNotActive(referrer);

        uint64 nowTs = uint64(block.timestamp);
        b.referrer = referrer;
        b.boundAt = nowTs;
        b.aliasUsed = aliasUsed;

        // Cannot realistically overflow: each increment needs a distinct address to bind, and
        // 0.8 checked arithmetic would revert rather than wrap if one ever did.
        r.refereeCount += 1;

        emit ReferralBound(referee, referrer, aliasUsed, nowTs);
    }
}
