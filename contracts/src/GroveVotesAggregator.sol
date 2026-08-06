// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {SGrove} from "./SGrove.sol";

/// @title GroveVotesAggregator — the Governor's single vote source (ADR-0026, L-02)
/// @notice Staking GROVE into the `SGrove` backstop must not disenfranchise the staker.
///         GROVE checkpoints votes for wallet balances; `SGrove` checkpoints votes for
///         ACTIVE stake. This contract is the read-only adapter the Governor points at,
///         so `FRGovernor` needs no surgery — it already accepts any `IVotes`.
///
///         **Voting power** is the SUM of both sources:
///           `getPastVotes(a, t) = grove.getPastVotes(a, t) + sGrove.getPastVotes(a, t)`
///         There is no double count, because `SGrove` deliberately leaves the GROVE it
///         custodies UNDELEGATED — that GROVE therefore contributes to NOBODY's balance
///         votes, and reappears exactly once, as the staker's sGROVE votes.
///
///         **Quorum** is deliberately NOT the sum:
///           `getPastTotalSupply(t) = grove.getPastTotalSupply(t)` — GROVE ONLY.
///         GROVE's total supply already contains the staked GROVE (it is held by the
///         `SGrove` contract, not burned), so summing the two supplies would inflate the
///         quorum denominator and silently raise the quorum bar for everyone. Worse, it
///         would be actively exploitable: a whale could stake immediately before a
///         proposal snapshot purely to raise the denominator and block a proposal it
///         opposed, then unbond. Sourcing quorum from GROVE alone removes that class
///         entirely and makes the denominator a constant — `GroveToken` mints once at
///         genesis and has no mint or burn path.
///
/// @dev IMMUTABLE AND ROLE-LESS BY DESIGN. Every other module in this repo is a UUPS
///      proxy administered by the timelock; this one is not, and the difference is
///      deliberate. `GovernorVotes` fixes its token at `initialize` with no setter, so
///      re-pointing the vote source is NOT a parameter change: it takes a full `FRGovernor`
///      UUPS upgrade through the timelock (`_authorizeUpgrade` is `onlyGovernance`), with
///      the same blast radius as any other module upgrade. That is what makes this
///      contract's composition rule (sum for votes, GROVE-only for supply) part of the
///      governance trust base — freezing it means the rule cannot be changed without that
///      upgrade, not that it can never be changed at all.
///
///      Be precise about what that does NOT buy: both underlying vote sources remain
///      UUPS-upgradeable with `UPGRADER_ROLE` on the timelock, and an upgraded `SGrove`
///      implementation could write arbitrarily into its ERC-7201 Votes namespace,
///      including rewriting history. Immutability here freezes the COMPOSITION, not the
///      inputs. ADR-0026 records that honestly.
///
///      Deliberately absent from `PrivilegeAudit.moduleSet` / `HandoverOps._modules` for
///      the same documented reason `FRGovernor` is: it holds no AccessControl roles, so
///      a `hasRole` scan would revert. It has no privileged functions at all.
contract GroveVotesAggregator is IERC5805 {
    /// @notice The GROVE governance token (balance votes).
    IVotes public immutable grove;
    /// @notice The staked-GROVE backstop (active-stake votes).
    SGrove public immutable sGrove;

    /// @notice A constructor argument was the zero address.
    error Aggregator_ZeroAddress();
    /// @notice A vote source does not use the timestamp clock this aggregator reports.
    /// @dev The single highest-value guard in this contract. `GovernorVotes.clock()` and
    ///      `CLOCK_MODE()` each wrap the token call in `try/catch` and FALL BACK TO BLOCK
    ///      NUMBERS on failure — silently. A `SGrove` that forgot to override `clock()`
    ///      would checkpoint in block numbers while GROVE checkpoints in timestamps, and
    ///      the mismatch surfaces only as every voter reading ~0 votes, or as every
    ///      proposal stuck `Pending` forever, with every other deploy check green. This
    ///      turns that into a deploy-time revert.
    error Aggregator_ClockMismatch(string expected, string actual);
    /// @notice A vote source DECLARES the timestamp clock but does not actually run on it.
    /// @dev `CLOCK_MODE()` is metadata; `clock()` is behaviour. A source can return
    ///      "mode=timestamp" while checkpointing in block numbers, and the string check alone
    ///      would wave it through into exactly the silent failure that check exists to prevent.
    ///      Comparing the live value closes the gap.
    error Aggregator_ClockValueMismatch(uint48 expected, uint48 actual);
    /// @notice Delegation is per-source and cannot be routed through the aggregator.
    /// @dev An account may have DIFFERENT delegates on GROVE and on sGROVE, so there is
    ///      no honest single answer for `delegates(account)` and no correct single target
    ///      for `delegate`. Returning one source's answer as if it were the whole picture
    ///      is exactly the silent partial truth CLAUDE.md forbids, so these fail loudly
    ///      instead. Use `groveDelegates` / `sGroveDelegates`, and delegate on each
    ///      source directly.
    error Aggregator_DelegateOnSource();
    /// @notice A vote source has no code — an EOA, or an address that has not been deployed yet.
    /// @dev Solidity's `extcodesize` guard fires BEFORE the call and outside the `try` below, so
    ///      a codeless source would otherwise still produce a bare empty-returndata revert. This
    ///      is the single likeliest deployer mistake (pasting a wallet address for a module), and
    ///      it deserves to say so.
    error Aggregator_NotAContract(address source);

    /// @dev Both sources are checked against this at construction.
    string private constant EXPECTED_CLOCK_MODE = "mode=timestamp";

    /// @param grove_ The GROVE governance token.
    /// @param sGrove_ The staked-GROVE backstop.
    constructor(address grove_, address sGrove_) {
        if (grove_ == address(0) || sGrove_ == address(0)) revert Aggregator_ZeroAddress();
        grove = IVotes(grove_);
        sGrove = SGrove(sGrove_);
        _requireTimestampClock(grove_);
        _requireTimestampClock(sGrove_);
    }

    // ── the Governor's read path ─────────────────────────────────────────

    /// @inheritdoc IVotes
    /// @notice Voting power at a past timepoint: wallet GROVE votes PLUS staked-GROVE votes.
    /// @dev NEITHER leg is wrapped in `try/catch`, deliberately. A swallowed revert would
    ///      silently drop every staker's votes — and worse, a relayer submitting someone's
    ///      `castVoteBySig` with a tight gas limit could force the swallow for that voter
    ///      alone, consuming their signature at a reduced weight. Both legs are pure
    ///      storage reads over checkpoint arrays; the only realistic way either reverts is
    ///      a governance-authored upgrade of its own vote source, and the pre-L-02 design
    ///      already accepts exactly that risk for GROVE, whose `getPastVotes` the Governor
    ///      has always called unwrapped. ADR-0026 records the trade-off and the alternative.
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256) {
        return grove.getPastVotes(account, timepoint) + sGrove.getPastVotes(account, timepoint);
    }

    /// @inheritdoc IVotes
    /// @notice The quorum denominator: GROVE total supply ONLY — see the contract NatSpec.
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256) {
        return grove.getPastTotalSupply(timepoint);
    }

    /// @inheritdoc IVotes
    /// @notice Current voting power across both sources.
    /// @dev Not used by the Governor (which only ever reads the past), but it IS the
    ///      correct quantity for the deploy-time governance-liveness assertions in
    ///      `Validate.s.sol` / `Handover.s.sol` and for any UI showing "your voting power".
    ///      Reading GROVE alone there would report a fully-staked treasury as having no
    ///      votes and declare healthy governance dead.
    function getVotes(address account) external view returns (uint256) {
        return grove.getVotes(account) + sGrove.getVotes(account);
    }

    // ── EIP-6372 clock ───────────────────────────────────────────────────

    /// @notice EIP-6372 clock. Timestamps, matching both vote sources.
    /// @dev Hardcoded, NOT forwarded to `grove.clock()`. An external call here could
    ///      revert and be swallowed by `GovernorVotes`'s `try/catch`, silently flipping
    ///      the Governor to block numbers. The constructor already proved both sources
    ///      agree with this value.
    function clock() external view returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice EIP-6372 machine-readable clock description.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return EXPECTED_CLOCK_MODE;
    }

    // ── delegation is per-source ─────────────────────────────────────────

    /// @notice Who `account` has delegated their wallet GROVE to.
    function groveDelegates(address account) external view returns (address) {
        return grove.delegates(account);
    }

    /// @notice Who `account` has delegated their staked GROVE to.
    function sGroveDelegates(address account) external view returns (address) {
        return sGrove.delegates(account);
    }

    /// @inheritdoc IVotes
    /// @dev Always reverts — delegation is per-source. See `Aggregator_DelegateOnSource`.
    function delegates(address) external pure returns (address) {
        revert Aggregator_DelegateOnSource();
    }

    /// @inheritdoc IVotes
    /// @dev Always reverts — delegate on GROVE and on sGROVE directly.
    function delegate(address) external pure {
        revert Aggregator_DelegateOnSource();
    }

    /// @inheritdoc IVotes
    /// @dev Always reverts — delegate on GROVE and on sGROVE directly.
    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external pure {
        revert Aggregator_DelegateOnSource();
    }

    // ── internals ────────────────────────────────────────────────────────

    /// @dev Reverts unless `source` both DECLARES and RUNS ON the timestamp clock this
    ///      aggregator reports. Both halves are needed: the string is what off-chain tooling
    ///      and `Validate.s.sol` read, and the value is what the checkpoint keys are actually
    ///      made of. A source that agrees on one and not the other is exactly the silent
    ///      mismatch this guard exists to make loud.
    /// @param source A vote source to check.
    function _requireTimestampClock(address source) private view {
        if (source.code.length == 0) revert Aggregator_NotAContract(source);
        // The `try` is NOT here to tolerate a failure -- it re-throws either way. It exists so
        // that wiring a plain ERC-20, an EOA, or any non-IERC5805 address fails with a NAMED
        // error instead of the bare empty-returndata revert the raw call would produce
        // (CLAUDE.md prime directive 4). An empty `actual` is the signature of "this address
        // is not a vote source at all", which is exactly what a deployer needs to be told.
        try IERC5805(source).CLOCK_MODE() returns (string memory mode) {
            if (keccak256(bytes(mode)) != keccak256(bytes(EXPECTED_CLOCK_MODE))) {
                revert Aggregator_ClockMismatch(EXPECTED_CLOCK_MODE, mode);
            }
        } catch {
            revert Aggregator_ClockMismatch(EXPECTED_CLOCK_MODE, "");
        }
        uint48 sourceClock = IERC5805(source).clock();
        if (sourceClock != uint48(block.timestamp)) {
            revert Aggregator_ClockValueMismatch(uint48(block.timestamp), sourceClock);
        }
    }
}
