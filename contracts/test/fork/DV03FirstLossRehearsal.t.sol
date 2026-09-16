// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface ICurator {
    function postFirstLoss(uint256 classId, uint256 amount) external;
    function poolBalance(uint256 classId) external view returns (uint256);
    function requiredFirstLoss(uint256 classId) external view returns (uint256);
    function isApprovedCurator(uint256 classId, address curator) external view returns (bool);
    function postedOf(uint256 classId, address curator) external view returns (uint256);
}

interface IReserves {
    function totalBackingValue() external view returns (uint256);
}

interface IController {
    function backingInvariantHolds() external view returns (bool);
}

/// @notice Rehearsal for DV-03: fund the curator first-loss layer, which the Corrovera mainnet-v1
///         audit reports as EMPTY ON CHAIN, so a declared default drives full principal onto the
///         senior NAV with nothing in front of it.
///
///         Route chosen by Forest Road 2026-08-28: transfer the existing 100 USDfr held by
///         `0x7fde637d…` rather than minting fresh. That satisfies the on-chain requirement and
///         adds no new capital; it is recorded here so the record is not read as more than it is.
///
///         This rehearses the exact three transactions a human will sign. It cannot prove the
///         signing path — the keys are not available here — but it proves the sequence, the
///         preconditions, the resulting state, and that no transaction reverts.
contract DV03FirstLossRehearsal is Test {
    address constant USDFR = 0xBf5014bfAeDA2c3A33e4Bf8Abb8263F31BB36bbf;
    address constant CURATOR = 0x30652De57A40448E22ee62C36F327656eAEE94FE;
    address constant RESERVES = 0x35683472E609249A6750ecDB850EFfde8a88CFF1;
    address constant CONTROLLER = 0xbd2e71C8cf6D989E746116D5D0d622C44d498da5;

    address constant ANCHOR_CURATOR = 0x02C7608407E1A2f55E795bBf4Ee69A0F18a59066;
    address constant HOLDER = 0x7FDe637d685A5486CCb1B0a8eF658Ad1a08e8337;

    uint256 constant CLASS = 2;
    uint256 constant AMOUNT = 100e18;

    /// @dev The `contracts` CI job deliberately carries no fork RPC secret. Skip there rather
    ///      than fail: a hard envString turned an intended skip into a red suite.
    bool internal forkReady;

    modifier onFork() {
        vm.skip(!forkReady);
        _;
    }

    function setUp() public {
        string memory forkUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(forkUrl).length == 0) return;
        vm.createSelectFork(forkUrl, 25853392);
        forkReady = true;
    }

    /// @dev Everything that must already be true before a human signs anything. If any of these
    ///      fails, the ceremony is not ready and no transaction should be broadcast.
    function test_preconditions_hold_on_live_state() public onFork {
        assertTrue(ICurator(CURATOR).isApprovedCurator(CLASS, ANCHOR_CURATOR), "curator not approved on class 2");
        assertEq(ICurator(CURATOR).requiredFirstLoss(CLASS), AMOUNT, "required first loss moved");
        assertEq(ICurator(CURATOR).poolBalance(CLASS), 0, "pool is not empty; re-read DV-03 before posting");
        // >= not ==: Forest Road minted a further 300 USDfr at block 25853377 while this was
        // being prepared, so the source wallet holds more than the amount being posted. What
        // matters is that it can cover it, not that it holds it exactly.
        assertGe(IERC20(USDFR).balanceOf(HOLDER), AMOUNT, "source wallet cannot cover the amount");
        assertEq(IERC20(USDFR).balanceOf(ANCHOR_CURATOR), 0, "curator already holds USDfr; re-check the plan");
        assertTrue(IController(CONTROLLER).backingInvariantHolds(), "backing invariant already violated");
    }

    /// @dev The three transactions, in order, exactly as they will be signed.
    function test_rehearsal_the_three_transactions() public onFork {
        uint256 supplyBefore = IERC20(USDFR).totalSupply();
        uint256 holderBefore = IERC20(USDFR).balanceOf(HOLDER);
        uint256 backingBefore = IReserves(RESERVES).totalBackingValue();

        // 1. HOLDER -> ANCHOR_CURATOR, 100 USDfr. Permissionless: `canTransfer` gates only on
        //    sanctions, never on the allowlist, so this needs no KYC on either side.
        vm.prank(HOLDER);
        assertTrue(IERC20(USDFR).transfer(ANCHOR_CURATOR, AMOUNT), "transfer returned false");
        assertEq(IERC20(USDFR).balanceOf(ANCHOR_CURATOR), AMOUNT, "curator did not receive");

        // 2. ANCHOR_CURATOR approves the CuratorModule to pull it.
        vm.prank(ANCHOR_CURATOR);
        assertTrue(IERC20(USDFR).approve(CURATOR, AMOUNT), "approve returned false");
        assertEq(IERC20(USDFR).allowance(ANCHOR_CURATOR, CURATOR), AMOUNT, "allowance not set");

        // 3. ANCHOR_CURATOR posts it as class-2 first loss.
        vm.prank(ANCHOR_CURATOR);
        ICurator(CURATOR).postFirstLoss(CLASS, AMOUNT);

        // The assertion DV-03 actually turns on.
        assertEq(ICurator(CURATOR).poolBalance(CLASS), AMOUNT, "first-loss layer still not funded");
        assertGe(
            ICurator(CURATOR).poolBalance(CLASS),
            ICurator(CURATOR).requiredFirstLoss(CLASS),
            "pool below the required first loss"
        );
        assertEq(ICurator(CURATOR).postedOf(CLASS, ANCHOR_CURATOR), AMOUNT, "stake not attributed to the curator");

        // Conservation: this route moves existing USDfr, it does not create any. Supply must not
        // change, and the backing invariant must still hold.
        assertEq(IERC20(USDFR).totalSupply(), supplyBefore, "supply changed; this route must not mint");
        assertEq(IERC20(USDFR).balanceOf(ANCHOR_CURATOR), 0, "curator should hold nothing after posting");
        assertEq(IERC20(USDFR).balanceOf(HOLDER), holderBefore - AMOUNT, "holder debited by exactly the amount");
        assertEq(IERC20(USDFR).balanceOf(CURATOR), AMOUNT, "module did not take custody");
        assertTrue(IController(CONTROLLER).backingInvariantHolds(), "backing invariant broken by the post");

        console2.log("poolBalance(2) after:      ", ICurator(CURATOR).poolBalance(CLASS));
        console2.log("requiredFirstLoss(2):      ", ICurator(CURATOR).requiredFirstLoss(CLASS));
        console2.log("USDfr totalSupply before:  ", supplyBefore);
        console2.log("USDfr totalSupply after:   ", IERC20(USDFR).totalSupply());
        console2.log("totalBackingValue before:  ", backingBefore);
        console2.log("totalBackingValue after:   ", IReserves(RESERVES).totalBackingValue());
    }

    /// @dev The ordering constraint, stated as a test so nobody discovers it while signing.
    function test_posting_without_the_approval_reverts() public onFork {
        vm.prank(HOLDER);
        IERC20(USDFR).transfer(ANCHOR_CURATOR, AMOUNT);
        vm.prank(ANCHOR_CURATOR);
        vm.expectRevert();
        ICurator(CURATOR).postFirstLoss(CLASS, AMOUNT);
    }

    /// @dev Only an approved curator may post, so a mis-sent transaction from the wrong wallet
    ///      fails rather than parking value somewhere unexpected.
    function test_a_non_curator_cannot_post() public onFork {
        assertFalse(ICurator(CURATOR).isApprovedCurator(CLASS, HOLDER), "fixture assumption broken");
        vm.startPrank(HOLDER);
        IERC20(USDFR).approve(CURATOR, AMOUNT);
        vm.expectRevert();
        ICurator(CURATOR).postFirstLoss(CLASS, AMOUNT);
        vm.stopPrank();
    }
}
