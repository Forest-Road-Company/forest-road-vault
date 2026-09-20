// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccrualLoanSequencesTest} from "./AccrualLoanSequences.t.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {AccrualDebtReference} from "../helpers/AccrualDebtReference.sol";

/// @notice The existing 512-event property and 8,192-event witness, starting from legacy histories.
/// @dev The independent reference first earns and services the note before migration. Only its
///      reporting origin changes at import; its arithmetic epoch, cap and frozen basis are retained.
contract AccrualOpeningSequencesTest is AccrualLoanSequencesTest {
    using AccrualDebtReference for AccrualDebtReference.Note;

    function _fund(Run memory run, uint256 index, uint256 seed) internal override {
        Row memory row;
        row.id = ++run.nextId;
        AccrualDebtReference.Note memory n = row.note;
        n.scale = index < 2 ? 1e12 : 1;
        n.principal = (seed % 1e24 / n.scale + 2) * n.scale;
        n.ceiling = n.principal + ((seed >> 64) % (2 * n.principal / n.scale + 1)) * n.scale;
        n.year = seed & (1 << 200) == 0 ? 360 days : 365 days;
        n.rate = uint16((seed >> 96) % 10_001);
        n.interval = 90 days;
        uint64 age = uint64((seed >> 112) % 600 days + 1);
        uint64 started = run.at - age;
        n.due = started + n.interval;
        n.maturity = run.at + uint64((seed >> 144) % 1600 days + 360 days);
        n.pik = index % 2 == 1;
        n.open(started);
        uint64 serviced = started + age / 2;
        n.advance(serviced);
        uint256 paid = n.principal / n.scale / 3 * n.scale;
        if (paid != 0) n.pay(paid, 0, serviced);
        n.advance(run.at);

        AccrualLoans.Opening memory opening;
        opening.terms = AccrualLoans.Funding({
            principal: n.principal,
            balanceCeiling: n.ceiling,
            scale: n.scale,
            yearSeconds: n.year,
            rateBps: n.rate,
            fundedAt: run.at,
            nextPaymentDue: n.due,
            paymentInterval: n.interval,
            maturity: n.maturity,
            pik: n.pik,
            keys: _keys(index),
            frozenPikBasis: n.pik ? n.frozenBasis : 0
        });
        opening.interest = n.interest;
        opening.periodStart = n.epochStart;
        uint256 income = seed % 3 == 0 ? 0 : n.interest;
        if (n.pik && seed % 3 == 2) income += n.principal / 7;
        opening.recordedFace = n.principal + n.interest - income;
        assertEq(subject.importOpening(row.id, opening), income, "opening recognition differs from proved delta");

        // Reset reporting counters only. Future interest still uses the untouched historical cursor.
        n.original = opening.recordedFace;
        n.paid = 0;
        n.earned = income;
        run.rows[index] = row;
        ++run.calls[0];
    }
}
