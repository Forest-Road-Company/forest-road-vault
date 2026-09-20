// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeAccrualStatefulFixture} from "./NativeAccrualStatefulFixture.sol";
import {NativeOpeningFixture} from "./NativeOpeningFixture.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @dev Run the established independent accounting actions after a real legacy-book import.
abstract contract NativeOpeningStatefulFixture is NativeAccrualStatefulFixture, NativeOpeningFixture {
    function setUp() public virtual override(NativeAccrualStatefulFixture, NativeOpeningFixture) {
        NativeOpeningFixture.setUp();
        _legacyFund(20_000e18);
        _prepareOne(nativeStart + 135 days + 123);
        _enableOpening();
        nativeOriginationFees = 20_000e18 / _nativeScale() * waterfall.originationFeeBps(Config.CLASS_FILM_TAX_CREDITS)
            / 10_000 * _nativeScale();
        vault.accrueFees();
        nativeLastRate = vault.currentExchangeRate();
        nativeActions[0] = 1;
        assertNativeStatefulAccounting();
    }
}
