// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {AccrualDebtReference} from "../helpers/AccrualDebtReference.sol";

/// @dev Local accounting adapter. Returned work is measured as the host's liabilities;
///      expected contractual debt is calculated separately by AccrualDebtReference.
contract AccrualLoanSequenceHarness {
    using AccrualLoans for AccrualLoans.State;
    using AccrualBook for AccrualBook.Book;

    AccrualLoans.State private state;

    constructor(uint64 at) {
        state.initialize(at, 1000);
    }

    function fund(uint256 id, AccrualLoans.Funding memory f) external {
        state.fund(id, f);
    }

    function importOpening(uint256 id, AccrualLoans.Opening memory opening) external returns (uint256) {
        return state.importOpening(id, opening);
    }

    function maintain(uint64 at, uint256 maximum) external returns (uint256 processed, bool fresh) {
        (, processed, fresh) = state.checkpoint(at, maximum);
    }

    function service(uint256 id, uint64 at) external {
        state.serviceDormant(id, at);
    }

    function pay(uint256 id, uint256 principal, uint256 interest, uint64 at)
        external
        returns (AccrualLoans.LifecycleWork memory)
    {
        return state.repay(id, principal, interest, at);
    }

    function amend(uint256 id, AccrualLoans.Amendment memory a, uint64 at)
        external
        returns (AccrualLoans.LifecycleWork memory)
    {
        return state.amend(id, a, at);
    }

    function stop(uint256 id, uint64 at) external returns (AccrualLoans.LifecycleWork memory) {
        return state.stop(id, at);
    }

    function post(uint256 id, uint64 at) external returns (uint256) {
        return state.post(id, at);
    }

    function mark(uint256 id, bool marked, uint64 at) external {
        state.book.setPastDue(id, marked, at);
    }

    function issue(uint8 legs, uint64 at) external returns (uint256, uint256) {
        return state.book.takeIssuance(legs, at);
    }

    function retire(uint256 id, uint64 at) external {
        state.retire(id, at);
    }

    function face(uint256 id, uint64 at) external view returns (uint256, uint256, uint64) {
        return state.loanFace(id, at);
    }

    function earned(uint256 id, uint64 at) external view returns (uint256) {
        return state.book.earned(id, at);
    }

    function group(bytes32 key, uint64 at) external view returns (uint256, uint256) {
        return (state.book.groupUnposted(key, at), state.book.pastDueInterest(key, at));
    }

    function snapshot(uint64 at) external view returns (AccrualBook.Snapshot memory) {
        return state.book.snapshot(at);
    }
}

contract AccrualLoanSequencesTest is Test {
    using AccrualDebtReference for AccrualDebtReference.Note;

    uint256 private constant COUNT = 4;
    uint64 private constant START = 1_900_000_000;

    struct Row {
        AccrualDebtReference.Note note;
        uint256 id;
        uint256 posted;
        uint256 corrections;
        bool marked;
        bool retired;
    }

    struct Run {
        Row[COUNT] rows;
        uint256 retiredIncome;
        uint256 posted;
        uint256 rounding;
        uint256 seniorIssued;
        uint256 feeIssued;
        uint256 nextId;
        uint256 maximumQuoteDifference;
        uint256 maximumDebtDifference;
        uint256 actions;
        uint256[9] calls;
        uint64 at;
    }

    AccrualLoanSequenceHarness internal subject;
    Run private savedRun;
    uint256 private savedSeed;

    function testFuzz_512EventsPreserveContractualDebtAndBoundBookDrift(uint256 seed) public {
        _sequence(seed, 512);
    }

    function test_8192EventsMeasureAccumulatedDebtDrift() public {
        savedSeed = uint256(keccak256("continuous accrual debt sequence"));
        _save(_start(savedSeed));
        for (uint256 chunk; chunk < 64; ++chunk) {
            this.sequenceChunk(chunk == 63);
        }
    }

    /// @dev Call boundaries discard temporary assertion memory between 128-event chunks.
    ///      The independent note state and seed persist, so this remains one 8,192-event history.
    function sequenceChunk(bool finish) external {
        require(msg.sender == address(this), "sequence fixture only");
        Run memory run = savedRun;
        savedSeed = _events(run, savedSeed, 128);
        if (finish) {
            _finish(run);
            _report(run);
        }
        _save(run);
    }

    function _save(Run memory run) private {
        for (uint256 i; i < COUNT; ++i) {
            savedRun.rows[i] = run.rows[i];
        }
        savedRun.retiredIncome = run.retiredIncome;
        savedRun.posted = run.posted;
        savedRun.rounding = run.rounding;
        savedRun.seniorIssued = run.seniorIssued;
        savedRun.feeIssued = run.feeIssued;
        savedRun.nextId = run.nextId;
        savedRun.maximumQuoteDifference = run.maximumQuoteDifference;
        savedRun.maximumDebtDifference = run.maximumDebtDifference;
        savedRun.actions = run.actions;
        savedRun.calls = run.calls;
        savedRun.at = run.at;
    }

    function test_quarterlyPikBasisSurvivesPaymentAndRateAmendment() public {
        Run memory run = _start(1);
        Row memory row = run.rows[1];
        _amend(run, 1, 1400, 90 days - 1);
        _advance(run, run.at + 30 days, 1);
        _pay(run, 1, 1);
        uint256 frozen = row.note.frozenBasis;
        _amend(run, 1, 2000, 60 days - 1);
        assertEq(row.note.frozenBasis, frozen, "reference rebased at amendment");
        _advance(run, row.note.due, 3);
        _assertRun(run);
        _finish(run);
    }

    function test_cashInterestRemainsSeparateThroughQuarterlyReceipts() public {
        Run memory run = _start(9);
        for (uint256 quarter; quarter < 4; ++quarter) {
            _advance(run, run.at + 90 days, 2);
            Row memory row = run.rows[0];
            uint256 principal = row.note.principal;
            uint256 interest = row.note.interest;
            if (interest != 0) {
                row.note.pay(0, interest, run.at);
                _record(run, 0, subject.pay(row.id, 0, interest, run.at));
            }
            assertEq(row.note.principal, principal, "cash compounded");
            _assertRun(run);
        }
        _finish(run);
    }

    function _sequence(uint256 seed, uint256 steps) private {
        Run memory run = _start(seed);
        _events(run, seed, steps);
        _finish(run);
    }

    function _events(Run memory run, uint256 seed, uint256 steps) private returns (uint256) {
        for (uint256 step; step < steps; ++step) {
            seed = uint256(keccak256(abi.encode(seed, run.actions)));
            uint256 index = (seed >> 16) % COUNT;
            uint256 action = seed % 10;
            if (action <= 2) {
                _advance(run, run.at + uint64((seed >> 64) % 150 days + 1), seed);
            } else if (action == 3) {
                _pay(run, index, seed >> 32);
            } else if (action == 4) {
                _amend(run, index, uint16((seed >> 32) % 10_001), seed >> 48);
            } else if (action == 5) {
                Row memory row = run.rows[index];
                if (!row.retired) {
                    row.note.stop(run.at);
                    _record(run, index, subject.stop(row.id, run.at));
                    ++run.calls[4];
                }
            } else if (action == 6) {
                _mark(run, index);
            } else if (action == 7) {
                _post(run, index);
            } else if (action == 8) {
                _issue(run, uint8((seed >> 32) % 3 + 1));
            } else {
                _replace(run, index, seed);
            }
            ++run.actions;
            _assertRun(run);
        }
        return seed;
    }

    function _report(Run memory run) private {
        emit log_named_uint("events", run.actions);
        emit log_named_uint("funded notes", run.nextId);
        emit log_named_uint("maximum aggregate quote difference in wei", run.maximumQuoteDifference);
        emit log_named_uint("explicit cumulative rounding loss in wei", run.rounding);
        emit log_named_uint("maximum contractual debt difference in wei", run.maximumDebtDifference);
        emit log_named_uint("fund calls", run.calls[0]);
        emit log_named_uint("time advances", run.calls[1]);
        emit log_named_uint("payment calls", run.calls[2]);
        emit log_named_uint("amendment calls", run.calls[3]);
        emit log_named_uint("stop calls", run.calls[4]);
        emit log_named_uint("past-due changes", run.calls[5]);
        emit log_named_uint("posting calls", run.calls[6]);
        emit log_named_uint("issuance calls", run.calls[7]);
        emit log_named_uint("processed scheduled boundaries", run.calls[8]);
        for (uint256 i; i < run.calls.length; ++i) {
            assertGt(run.calls[i], 0, "event class not reached");
        }
    }

    function _start(uint256 seed) private returns (Run memory run) {
        run.at = START;
        subject = new AccrualLoanSequenceHarness(run.at);
        for (uint256 i; i < COUNT; ++i) {
            _fund(run, i, uint256(keccak256(abi.encode(seed, i))));
        }
        _assertRun(run);
    }

    function _fund(Run memory run, uint256 index, uint256 seed) internal virtual {
        Row memory row;
        row.id = ++run.nextId;
        AccrualDebtReference.Note memory n = row.note;
        n.scale = index < 2 ? 1e12 : 1;
        n.principal = (seed % 1e24 / n.scale + 2) * n.scale;
        n.ceiling = n.principal + ((seed >> 64) % (2 * n.principal / n.scale + 1)) * n.scale;
        n.year = seed & (1 << 200) == 0 ? 360 days : 365 days;
        n.rate = uint16((seed >> 96) % 10_001);
        n.interval = 90 days;
        n.due = run.at + 90 days;
        n.maturity = run.at + uint64((seed >> 144) % 1600 days + 360 days);
        n.pik = index % 2 == 1;
        n.open(run.at);
        run.rows[index] = row;
        AccrualLoans.Funding memory f;
        f.principal = n.principal;
        f.balanceCeiling = n.ceiling;
        f.scale = n.scale;
        f.yearSeconds = n.year;
        f.rateBps = n.rate;
        f.fundedAt = run.at;
        f.nextPaymentDue = n.due;
        f.paymentInterval = n.interval;
        f.maturity = n.maturity;
        f.pik = n.pik;
        f.keys = _keys(index);
        subject.fund(row.id, f);
        ++run.calls[0];
    }

    function _advance(Run memory run, uint64 at, uint256 seed) private {
        for (uint256 i; i < COUNT; ++i) {
            run.rows[i].note.advance(at);
        }
        bool fresh;
        uint256 calls;
        while (!fresh) {
            uint256 processed;
            (processed, fresh) = subject.maintain(at, seed % 32 + 1);
            run.calls[8] += processed;
            assertLt(++calls, 256, "maintenance did not converge");
        }
        run.at = at;
        ++run.calls[1];
        for (uint256 i; i < COUNT; ++i) {
            if (!run.rows[i].retired) subject.service(run.rows[i].id, at);
        }
    }

    function _pay(Run memory run, uint256 index, uint256 seed) private {
        Row memory row = run.rows[index];
        AccrualDebtReference.Note memory n = row.note;
        if (row.retired || n.principal + n.interest == 0) return;
        uint256 principal;
        uint256 interest;
        if (n.pik) {
            principal = ((n.principal + n.interest) / n.scale / (seed % 7 + 1)) * n.scale;
        } else {
            principal = (n.principal / n.scale / (seed % 7 + 1)) * n.scale;
            interest = (n.interest / n.scale / ((seed >> 8) % 3 + 1)) * n.scale;
        }
        if (principal + interest == 0) return;
        n.pay(principal, interest, run.at);
        _record(run, index, subject.pay(row.id, principal, interest, run.at));
        ++run.calls[2];
    }

    function _amend(Run memory run, uint256 index, uint16 rate, uint256 seed) private {
        Row memory row = run.rows[index];
        AccrualDebtReference.Note memory n = row.note;
        if (row.retired || n.stopped) return;
        AccrualLoans.Amendment memory a;
        a.balanceCeiling = n.principal + n.interest + (seed % (n.original / n.scale + 1)) * n.scale;
        a.yearSeconds = seed % 2 == 0 ? 360 days : 365 days;
        a.rateBps = rate;
        a.nextPaymentDue = run.at + uint64(seed % 120 days + 1);
        a.paymentInterval = n.interval;
        n.amend(rate, a.balanceCeiling, a.yearSeconds, a.nextPaymentDue, run.at);
        a.maturity = n.maturity;
        _record(run, index, subject.amend(row.id, a, run.at));
        ++run.calls[3];
    }

    function _mark(Run memory run, uint256 index) private {
        Row memory row = run.rows[index];
        if (row.retired) return;
        row.marked = !row.marked;
        subject.mark(row.id, row.marked, run.at);
        ++run.calls[5];
    }

    function _post(Run memory run, uint256 index) private {
        Row memory row = run.rows[index];
        if (row.retired) return;
        uint256 amount = subject.post(row.id, run.at);
        run.posted += amount;
        row.posted += amount;
        ++run.calls[6];
    }

    function _issue(Run memory run, uint8 legs) private {
        (uint256 senior, uint256 fee) = subject.issue(legs, run.at);
        run.seniorIssued += senior;
        run.feeIssued += fee;
        ++run.calls[7];
    }

    function _replace(Run memory run, uint256 index, uint256 seed) private {
        Row memory row = run.rows[index];
        if (row.note.principal + row.note.interest != 0) return;
        if (!row.retired) subject.retire(row.id, run.at);
        run.retiredIncome += row.note.earned;
        _fund(run, index, seed);
    }

    function _record(Run memory run, uint256 index, AccrualLoans.LifecycleWork memory work) private pure {
        assertLt(work.roundingLoss, run.rows[index].note.scale, "rounding loss outside reserve unit");
        assertLe(work.positiveCorrection, run.rows[index].note.scale, "positive correction outside reserve unit");
        run.rounding += work.roundingLoss;
        run.posted += work.posting;
        run.rows[index].posted += work.posting;
        run.rows[index].corrections += work.roundingLoss;
    }

    function _assertRun(Run memory run) private view {
        AccrualBook.Snapshot memory s = subject.snapshot(run.at);
        assertTrue(s.fresh, "checkpoint left a stale read");
        assertEq(s.accruedThrough, run.at, "coherent frontier");
        assertEq(run.posted + s.unposted, s.gross, "posting conservation");
        assertEq(s.fee, s.gross / 10, "continuous protocol fee");
        assertEq(run.seniorIssued + s.seniorUnissued, s.gross - s.fee, "senior issuance conservation");
        assertEq(run.feeIssued + s.feeUnissued, s.fee, "fee issuance conservation");
        assertEq(s.unissued, s.seniorUnissued + s.feeUnissued, "unissued legs");
        uint256 contractualIncome = run.retiredIncome;
        for (uint256 i; i < COUNT; ++i) {
            Row memory row = run.rows[i];
            _assertRow(run, row);
            contractualIncome += row.note.earned;
        }
        // An open quote truncates its integer slope by less than one wei/second,
        // and its endpoints by less than one reserve unit. Closed discrepancies
        // must be present in the explicit host loss liability, not hidden in debt.
        uint256 expectedBook = contractualIncome + run.rounding;
        uint256 difference = s.gross > expectedBook ? s.gross - expectedBook : expectedBook - s.gross;
        assertLe(difference, 2e12 + COUNT * 365 days, "accumulated quote drift exceeded active curves");
        if (difference > run.maximumQuoteDifference) run.maximumQuoteDifference = difference;
        for (uint256 classId; classId < 2; ++classId) {
            _assertGroup(run, classId);
        }
    }

    function _assertRow(Run memory run, Row memory row) private view {
        (uint256 principal, uint256 interest, uint64 through) = subject.face(row.id, run.at);
        uint256 difference =
            principal > row.note.principal ? principal - row.note.principal : row.note.principal - principal;
        difference += interest > row.note.interest ? interest - row.note.interest : row.note.interest - interest;
        if (difference > run.maximumDebtDifference) run.maximumDebtDifference = difference;
        assertEq(through, run.at, "debt frontier");
        assertEq(principal, row.note.principal, "independent principal drift");
        assertEq(interest, row.note.interest, "independent interest drift");
        assertEq(principal + interest + row.note.paid, row.note.original + row.note.earned, "debt conservation");
        uint256 actualBook = row.retired ? row.posted : subject.earned(row.id, run.at);
        uint256 expectedBook = row.note.earned + row.corrections;
        uint256 bound = row.note.stopped || !row.note.active ? 0 : row.note.scale + 365 days;
        assertApproxEqAbs(actualBook, expectedBook, bound, "facility quote drift");
    }

    function _assertGroup(Run memory run, uint256 classId) private view {
        uint256 unposted;
        uint256 marked;
        for (uint256 i = classId; i < COUNT; i += 2) {
            Row memory row = run.rows[i];
            if (row.retired) continue;
            uint256 amount = subject.earned(row.id, run.at) - row.posted;
            unposted += amount;
            if (row.marked) marked += amount;
        }
        (uint256 actualUnposted, uint256 actualMarked) = subject.group(_keys(classId)[0], run.at);
        assertEq(actualUnposted, unposted, "class exposure cohort");
        assertEq(actualMarked, marked, "past-due cohort checkpoint");
    }

    function _finish(Run memory run) private {
        uint256 earned = run.retiredIncome;
        for (uint256 i; i < COUNT; ++i) {
            Row memory row = run.rows[i];
            row.note.stop(run.at);
            _record(run, i, subject.stop(row.id, run.at));
            _pay(run, i, 0);
            assertEq(row.note.principal + row.note.interest, 0, "final payment was incomplete");
            subject.retire(row.id, run.at);
            row.retired = true;
            row.marked = false;
            earned += row.note.earned;
        }
        _issue(run, 3);
        _assertRun(run);
        assertEq(subject.snapshot(run.at).gross, earned + run.rounding, "final book drift after explicit losses");
        assertEq(subject.snapshot(run.at).unposted, 0, "retirement left virtual face");
        assertEq(subject.snapshot(run.at).unissued, 0, "retirement left unissued income");
    }

    function _keys(uint256 index) internal pure returns (bytes32[3] memory keys) {
        keys[0] = keccak256(abi.encode("class", index % 2));
        keys[1] = keccak256(abi.encode("borrower", index));
        keys[2] = keccak256(abi.encode("state", index % 2));
    }
}
