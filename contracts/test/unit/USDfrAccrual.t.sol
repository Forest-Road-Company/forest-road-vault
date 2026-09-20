// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {USDfr} from "../../src/USDfr.sol";
import {IUSDfr} from "../../src/interfaces/IUSDfr.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {PointsHook_InsufficientGas} from "../../src/libraries/PointsHookGas.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @dev Independently programmable fixed-ABI counterparty. Malformed replies are deliberate:
///      the token must reject them before granting a mint leg, without decoder panics.
contract USDfrAccrualEndpoint {
    mapping(bytes4 => bytes) private _reply;
    mapping(bytes4 => bool) private _fail;

    function setReply(bytes4 selector, bytes memory reply) external {
        _reply[selector] = reply;
    }

    function setFail(bytes4 selector, bool fail) external {
        _fail[selector] = fail;
    }

    function relay(address target, bytes calldata data) external returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        require(!_fail[selector], "endpoint failure");
        return _reply[selector];
    }
}

contract USDfrAccrualCompliance {
    mapping(address => bool) public isProtocolExempt;
    address public blockedRecipient;
    address public attackTarget;
    bytes public attackData;
    bool public attackEnabled;

    function setExempt(address account, bool exempt) external {
        isProtocolExempt[account] = exempt;
    }

    function setBlockedRecipient(address account) external {
        blockedRecipient = account;
    }

    function configureAttack(address target, bytes memory data, bool enabled) external {
        attackTarget = target;
        attackData = data;
        attackEnabled = enabled;
    }

    function canTransfer(address, address, address to) external view returns (bool) {
        if (attackEnabled) {
            (bool ok, bytes memory result) = attackTarget.staticcall(attackData);
            require(!ok, "compliance nested mutation succeeded");
            require(
                keccak256(result) == keccak256(abi.encodeWithSelector(USDfr.USDfr_AccrualBatchActive.selector)),
                "compliance reached a write before the batch guard"
            );
        }
        return to != blockedRecipient;
    }
}

contract USDfrAccrualPoints {
    address public attackTarget;
    bytes public attackData;
    uint256 public callbacks;
    uint256 public rejectedAttacks;
    uint256 public firstRawSupply;
    uint256 public lastRawSupply;
    bool public failHook;
    bytes32 public expectedPermitHash;
    USDfr public token;
    IContinuousAccrual public reserve;

    constructor(USDfr token_, IContinuousAccrual reserve_) {
        token = token_;
        reserve = reserve_;
    }

    function configure(address target, bytes memory data, bool fail, bytes32 permitHash) external {
        attackTarget = target;
        attackData = data;
        failHook = fail;
        expectedPermitHash = permitHash;
        callbacks = 0;
        rejectedAttacks = 0;
        firstRawSupply = 0;
        lastRawSupply = 0;
    }

    function onUSDfrTransfer(address, address, uint256) external {
        require(msg.sender == address(token), "unexpected token");
        require(!failHook, "points unavailable");
        ++callbacks;
        if (callbacks == 1) firstRawSupply = token.totalSupply();
        lastRawSupply = token.totalSupply();
        if (expectedPermitHash != bytes32(0)) {
            require(
                keccak256(abi.encode(reserve.accrualDelivery())) == expectedPermitHash, "permit changed in callback"
            );
        }
        if (attackTarget != address(0)) {
            (bool ok, bytes memory result) = attackTarget.call(attackData);
            require(!ok, "points nested mutation succeeded");
            require(
                keccak256(result) == keccak256(abi.encodeWithSelector(USDfr.USDfr_AccrualBatchActive.selector)),
                "unexpected points callback failure"
            );
            ++rejectedAttacks;
        }
    }
}

contract USDfrAccrualExhaustingPoints {
    function onUSDfrTransfer(address, address, uint256) external pure {
        assembly ("memory-safe") {
            invalid()
        }
    }
}

/// @notice Isolated token delivery tests. The reserve double is intentionally trusted only as
///         the token's bound permit source. These tests do not prove host economic accounting.
contract USDfrAccrualTest is Test {
    USDfr private _token;
    USDfrAccrualEndpoint private _reserve;
    USDfrAccrualEndpoint private _controller;
    USDfrAccrualEndpoint private _vault;
    address private constant FEE_RECIPIENT = address(0xfee);
    address private constant HOLDER = address(0xa11ce);
    bytes4 private constant MODULES = IContinuousAccrual.accrualModules.selector;
    bytes4 private constant DELIVERY = IContinuousAccrual.accrualDelivery.selector;

    event AccrualReserveSet(address indexed reserve, address indexed controller, address indexed vault);
    event AccruedInterestMinted(
        uint256 indexed nonce, address indexed vault, address indexed feeRecipient, uint256 senior, uint256 fee
    );
    event Transfer(address indexed from, address indexed to, uint256 value);
    event PointsHookFailed(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        vm.warp(1000);
        _reserve = new USDfrAccrualEndpoint();
        _controller = new USDfrAccrualEndpoint();
        _vault = new USDfrAccrualEndpoint();
        _token = USDfr(
            address(
                new ERC1967Proxy(
                    address(new USDfr()),
                    abi.encodeCall(
                        USDfr.initialize, (address(this), address(_controller), address(this), address(this))
                    )
                )
            )
        );
        _validModuleReplies();
    }

    function test_bindingIsOneTimeAndEmitsValidatedIdentities() public {
        assertEq(_token.accrualReserve(), address(0));
        vm.expectEmit(true, true, true, true, address(_token));
        emit AccrualReserveSet(address(_reserve), address(_controller), address(_vault));
        _bind();
        assertEq(_token.accrualReserve(), address(_reserve));
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_AccrualReserveAlreadySet.selector, address(_reserve)));
        _token.setAccrualReserve(address(_reserve));
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_AccrualReserveAlreadySet.selector, address(_reserve)));
        _token.setAccrualReserve(address(0));
    }

    function test_bindingRejectsUnauthorizedCaller() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, HOLDER, bytes32(0))
        );
        vm.prank(HOLDER);
        _token.setAccrualReserve(address(_reserve));
    }

    function test_bindingRejectsCodelessReserve() public {
        _expectInvalidReserve(address(0));
        _expectInvalidReserve(HOLDER);
    }

    function test_bindingRejectsWrongTokenControllerVaultAndMissingMinter() public {
        IContinuousAccrual.Modules memory m = _modules();
        m.token = HOLDER;
        _invalidModules(m);
        m = _modules();
        m.controller = HOLDER;
        _invalidModules(m);
        m = _modules();
        m.vault = HOLDER;
        _invalidModules(m);
        _validModuleReplies();
        _token.revokeRole(Roles.MINTER_ROLE, address(_controller));
        _expectInvalidReserve(address(_reserve));
        _token.grantRole(Roles.MINTER_ROLE, address(_controller));
        _bind();
    }

    function test_bindingRejectsMalformedModuleRepliesAndRecovers() public {
        uint256[7] memory words = abi.decode(abi.encode(_modules()), (uint256[7]));
        for (uint256 i; i < 7; ++i) {
            uint256 old = words[i];
            words[i] = uint256(type(uint160).max) + 1;
            _reserve.setReply(MODULES, abi.encode(words));
            _expectInvalidReserve(address(_reserve));
            words[i] = old;
        }
        _reserve.setReply(MODULES, new bytes(223));
        _expectInvalidReserve(address(_reserve));
        _reserve.setReply(MODULES, new bytes(225));
        _expectInvalidReserve(address(_reserve));
        _reserve.setFail(MODULES, true);
        _expectInvalidReserve(address(_reserve));
        _reserve.setFail(MODULES, false);
        _validModuleReplies();
        _bind();
    }

    function test_bindingRejectsControllerModuleMismatchAndMalformedReplies() public {
        bytes4 selector = IMintRedeemController.modules.selector;
        _controller.setReply(selector, abi.encode(HOLDER, address(0), address(_reserve)));
        _expectInvalidReserve(address(_reserve));
        _controller.setReply(selector, abi.encode(address(_token), address(0), HOLDER));
        _expectInvalidReserve(address(_reserve));
        _controller.setReply(selector, abi.encode(address(_token), type(uint256).max, address(_reserve)));
        _expectInvalidReserve(address(_reserve));
        _controller.setReply(selector, new bytes(95));
        _expectInvalidReserve(address(_reserve));
        _controller.setReply(selector, new bytes(97));
        _expectInvalidReserve(address(_reserve));
        _controller.setFail(selector, true);
        _expectInvalidReserve(address(_reserve));
        _controller.setFail(selector, false);
        _validModuleReplies();
        _bind();
    }

    function test_bindingRejectsWrongOrMalformedVaultAsset() public {
        bytes4 selector = IERC4626.asset.selector;
        _vault.setReply(selector, abi.encode(HOLDER));
        _expectInvalidReserve(address(_reserve));
        _vault.setReply(selector, abi.encode(type(uint256).max));
        _expectInvalidReserve(address(_reserve));
        _vault.setReply(selector, new bytes(31));
        _expectInvalidReserve(address(_reserve));
        _vault.setReply(selector, new bytes(33));
        _expectInvalidReserve(address(_reserve));
        _vault.setFail(selector, true);
        _expectInvalidReserve(address(_reserve));
        _vault.setFail(selector, false);
        _validModuleReplies();
        _bind();
    }

    function test_deliveryRequiresBindingMinterAndPinnedController() public {
        vm.expectRevert(USDfr.USDfr_AccrualReserveNotSet.selector);
        _mintAccrued(1);
        _bind();
        _setDelivery(_delivery(1, 10, 3, 3));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, HOLDER, Roles.MINTER_ROLE)
        );
        vm.prank(HOLDER);
        _token.mintAccrued(1);
        _token.grantRole(Roles.MINTER_ROLE, HOLDER);
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_InvalidAccrualDelivery.selector, 1));
        vm.prank(HOLDER);
        _token.mintAccrued(1);
        _mintAccrued(1);
        assertEq(_token.totalSupply(), 13);
    }

    function test_deliveryMintsExactLegsAndEvents() public {
        _bind();
        _setDelivery(_delivery(1, 10, 3, 3));
        vm.expectEmit(true, true, false, true, address(_token));
        emit Transfer(address(0), address(_vault), 10);
        vm.expectEmit(true, true, false, true, address(_token));
        emit Transfer(address(0), FEE_RECIPIENT, 3);
        vm.expectEmit(true, true, true, true, address(_token));
        emit AccruedInterestMinted(1, address(_vault), FEE_RECIPIENT, 10, 3);
        _mintAccrued(1);
        assertEq(_token.totalSupply(), 13);
        assertEq(_token.balanceOf(address(_vault)), 10);
        assertEq(_token.balanceOf(FEE_RECIPIENT), 3);
    }

    function testFuzz_deliveryExactSelectedDeltas(
        uint128 seniorSeed,
        uint128 feeSeed,
        uint8 maskSeed,
        bool aliasRecipients,
        bool pauseToken
    ) public {
        _bind();
        _ordinaryMint(address(_vault), 23);
        _ordinaryMint(FEE_RECIPIENT, 31);
        uint8 mask = maskSeed % 3 + 1;
        uint256 senior = mask & 1 == 0 ? 0 : uint256(seniorSeed) + 1;
        uint256 fee = mask & 2 == 0 ? 0 : uint256(feeSeed) + 1;
        IContinuousAccrual.Delivery memory d = _delivery(1, senior, fee, mask);
        if (aliasRecipients) d.feeRecipient = address(_vault);
        _setDelivery(d);
        if (pauseToken) _token.pause();
        _mintAccrued(1);
        assertEq(_token.totalSupply(), 54 + senior + fee);
        assertEq(_token.balanceOf(address(_vault)), 23 + senior + (aliasRecipients ? fee : 0));
        assertEq(_token.balanceOf(FEE_RECIPIENT), 31 + (aliasRecipients ? 0 : fee));
    }

    function test_deliveryAllowsEitherZeroLegButRejectsBothZero() public {
        _bind();
        _setDelivery(_delivery(1, 0, 7, 3));
        _mintAccrued(1);
        IContinuousAccrual.Delivery memory d = _delivery(2, 11, 0, 3);
        d.feeRecipient = address(0); // No fee is sent, so this is not an invalid receiver.
        _setDelivery(d);
        _mintAccrued(2);
        _setDelivery(_delivery(3, 0, 0, 3));
        _expectInvalidDelivery(3);
        assertEq(_token.totalSupply(), 18);
    }

    function testFuzz_deliverySupportsFullWidthSupplyAndLegs(uint256 existingSeed, uint256 seniorSeed, uint256 feeSeed)
        public
    {
        _bind();
        uint256 existing = existingSeed / 2;
        uint256 senior = bound(seniorSeed, 0, type(uint256).max - existing);
        uint256 fee = bound(feeSeed, 0, type(uint256).max - existing - senior);
        if (senior == 0 && fee == 0) senior = 1;
        _ordinaryMint(HOLDER, existing);
        _setDelivery(_delivery(1, senior, fee, 3));
        _mintAccrued(1);
        assertEq(_token.totalSupply(), existing + senior + fee);
        assertEq(_token.balanceOf(HOLDER), existing);
        assertEq(_token.balanceOf(address(_vault)), senior);
        assertEq(_token.balanceOf(FEE_RECIPIENT), fee);
    }

    function test_deliveryAcceptsLastRepresentableTimeAndRejectsTruncation() public {
        _bind();
        vm.warp(type(uint64).max);
        _setDelivery(_delivery(1, 10, 3, 3));
        _mintAccrued(1);
        vm.warp(uint256(type(uint64).max) + 1);
        _setDelivery(_delivery(2, 10, 3, 3));
        _expectInvalidDelivery(2);
        assertEq(_token.totalSupply(), 13);
    }

    function test_deliveryRejectsEveryInvalidPermitFieldWithoutConsumingNonce() public {
        _bind();
        for (uint256 mode; mode < 14; ++mode) {
            IContinuousAccrual.Delivery memory d = _delivery(1, 10, 3, 3);
            if (mode == 0) {
                d.active = false;
            } else if (mode == 1) {
                d.nonce = 2;
            } else if (mode == 2) {
                d.accruedThrough -= 1;
            } else if (mode == 3) {
                d.accruedThrough += 1;
            } else if (mode == 4) {
                d.legs = 0;
            } else if (mode == 5) {
                d.legs = 4;
            } else if (mode == 6) {
                d.legs = type(uint8).max;
            } else if (mode == 7) {
                d.legs = 1;
            } else if (mode == 8) {
                d.legs = 2;
            } else if (mode == 9) {
                d.feeRecipient = address(0);
            } else if (mode == 10) {
                d.controller = HOLDER;
            } else if (mode == 11) {
                d.vault = HOLDER;
            } else if (mode == 12) {
                d.pricing.materializationAllowed = false;
            } else {
                d.senior = 0;
                d.fee = 0;
            }
            _setDelivery(d);
            _expectInvalidDelivery(1);
            assertEq(_token.totalSupply(), 0);
        }
        _setDelivery(_delivery(1, 10, 3, 3));
        _mintAccrued(1);
        assertEq(_token.totalSupply(), 13);
    }

    function test_deliveryRejectsMalformedAbiWithNamedError() public {
        _bind();
        _expectInvalidDelivery(1); // Empty fallback output.
        _reserve.setReply(DELIVERY, new bytes(575));
        _expectInvalidDelivery(1);
        _reserve.setReply(DELIVERY, new bytes(577));
        _expectInvalidDelivery(1);
        _reserve.setFail(DELIVERY, true);
        _expectInvalidDelivery(1);
        _reserve.setFail(DELIVERY, false);
        uint256[18] memory words = abi.decode(abi.encode(_delivery(1, 10, 3, 3)), (uint256[18]));
        uint256[7] memory indices = [uint256(11), 12, 13, 14, 15, 16, 17];
        for (uint256 i; i < indices.length; ++i) {
            uint256 index = indices[i];
            uint256 old = words[index];
            words[index] = type(uint256).max;
            _reserve.setReply(DELIVERY, abi.encode(words));
            _expectInvalidDelivery(1);
            words[index] = old;
        }
        _setDelivery(_delivery(1, 10, 3, 3));
        _mintAccrued(1);
    }

    function test_deliveryRejectsMissingInactivePermitAndWrongSource() public {
        _bind();
        _setDelivery(
            IContinuousAccrual.Delivery({
                nonce: 0,
                senior: 0,
                fee: 0,
                effectiveSupply: 0,
                backing: 0,
                recognizedBacking: 0,
                pricing: IContinuousAccrual.PricingState(0, 0, 0, 0, 0, false),
                controller: address(0),
                vault: address(0),
                feeRecipient: address(0),
                accruedThrough: 0,
                legs: 0,
                active: false
            })
        );
        USDfrAccrualEndpoint unbound = new USDfrAccrualEndpoint();
        unbound.setReply(DELIVERY, abi.encode(_delivery(1, 10, 3, 3)));
        _expectInvalidDelivery(1);
        assertEq(_token.totalSupply(), 0);
    }

    function testFuzz_deliveryNonceStrictlyIncreases(uint256 nonceSeed) public {
        _bind();
        uint256 nonce = bound(nonceSeed, 1, type(uint256).max);
        _setDelivery(_delivery(nonce, 10, 3, 3));
        _mintAccrued(nonce);
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_AccrualNonceUsed.selector, nonce, nonce));
        _mintAccrued(nonce);
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_AccrualNonceUsed.selector, nonce - 1, nonce));
        _mintAccrued(nonce - 1);
        if (nonce != type(uint256).max) {
            _setDelivery(_delivery(nonce + 1, 1, 0, 1));
            _mintAccrued(nonce + 1);
            assertEq(_token.totalSupply(), 14);
        } else {
            assertEq(_token.totalSupply(), 13);
        }
    }

    function test_deliveryNonceZeroNeverAuthorizesMint() public {
        _bind();
        _setDelivery(_delivery(0, 10, 3, 3));
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_AccrualNonceUsed.selector, 0, 0));
        _mintAccrued(0);
    }

    function test_deliveryRejectsAmountOrSupplyOverflowBeforeMint() public {
        _bind();
        IContinuousAccrual.Delivery memory d = _delivery(1, 10, 3, 3);
        d.senior = type(uint256).max;
        d.fee = 1;
        _setDelivery(d);
        _expectInvalidDelivery(1);
        _ordinaryMint(HOLDER, type(uint256).max - 5);
        d.senior = 5;
        d.fee = 1;
        _setDelivery(d);
        _expectInvalidDelivery(1);
        assertEq(_token.balanceOf(address(_vault)), 0);
        d.senior = 4;
        _setDelivery(d);
        _mintAccrued(1);
        assertEq(_token.totalSupply(), type(uint256).max);
    }

    function test_secondLegComplianceFailureRollsBackFirstLegAndNonce() public {
        _bind();
        USDfrAccrualCompliance compliance = new USDfrAccrualCompliance();
        _token.setComplianceModule(address(compliance));
        compliance.setBlockedRecipient(FEE_RECIPIENT);
        _ordinaryMint(HOLDER, 17);
        _setDelivery(_delivery(1, 10, 3, 3));
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, address(0), FEE_RECIPIENT));
        _mintAccrued(1);
        assertEq(_token.totalSupply(), 17);
        assertEq(_token.balanceOf(address(_vault)), 0);
        assertEq(_token.balanceOf(FEE_RECIPIENT), 0);
        compliance.setBlockedRecipient(address(0));
        _mintAccrued(1);
        assertEq(_token.totalSupply(), 30);
        _ordinaryMint(HOLDER, 1); // A reverted batch cannot strand the normal path.
        _token.approve(HOLDER, 1);
        _token.setPointsModule(address(0));
        _token.grantRole(Roles.MINTER_ROLE, HOLDER);
        assertEq(_token.totalSupply(), 31);
    }

    function test_pausedExceptionIsOnlyForExactAccrualDelivery() public {
        _bind();
        _ordinaryMint(HOLDER, 17);
        _setDelivery(_delivery(1, 10, 3, 3));
        _token.pause();
        _mintAccrued(1); // No compliance directory is necessary for this narrow exception.
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _ordinaryMint(address(_vault), 1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(HOLDER);
        _token.transfer(FEE_RECIPIENT, 1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(address(_controller));
        _token.burn(HOLDER, 1);
        assertEq(_token.totalSupply(), 30);
        _token.unpause();
        _ordinaryMint(HOLDER, 1);
    }

    function test_pausedComplianceStillAppliesAndNativeInternalBurnRemainsLive() public {
        _bind();
        USDfrAccrualCompliance compliance = new USDfrAccrualCompliance();
        _token.setComplianceModule(address(compliance));
        compliance.setExempt(address(_vault), true);
        compliance.setExempt(FEE_RECIPIENT, true);
        _ordinaryMint(address(_vault), 17);
        _token.pause();
        compliance.setBlockedRecipient(FEE_RECIPIENT);
        _setDelivery(_delivery(1, 10, 3, 3));
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, address(0), FEE_RECIPIENT));
        _mintAccrued(1);
        compliance.setBlockedRecipient(address(0xdead));
        _mintAccrued(1);
        vm.prank(address(_vault));
        _token.transfer(FEE_RECIPIENT, 2);
        vm.prank(address(_controller));
        _token.burn(address(_vault), 4);
        assertEq(_token.totalSupply(), 26);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _ordinaryMint(address(_vault), 1);
    }

    /// @dev Compliance is STATICCALLed. The exact-leg arm must already be consumed: otherwise
    ///      a nested controller mint could reach an SSTORE and fail for static context instead.
    function test_complianceCannotReuseExactLegEvenThroughPinnedController() public {
        _bind();
        USDfrAccrualCompliance compliance = new USDfrAccrualCompliance();
        _token.setComplianceModule(address(compliance));
        compliance.configureAttack(
            address(_controller),
            abi.encodeCall(
                USDfrAccrualEndpoint.relay, (address(_token), abi.encodeCall(USDfr.mint, (address(_vault), 10)))
            ),
            true
        );
        _setDelivery(_delivery(1, 10, 0, 1));
        _token.pause();
        _mintAccrued(1);
        assertEq(_token.totalSupply(), 10);
    }

    function test_pointsCannotReuseExactLegThroughPinnedController() public {
        _bind();
        USDfrAccrualPoints points = _points();
        IContinuousAccrual.Delivery memory d = _delivery(1, 10, 3, 3);
        _setDelivery(d);
        points.configure(
            address(_controller),
            abi.encodeCall(
                USDfrAccrualEndpoint.relay, (address(_token), abi.encodeCall(USDfr.mint, (address(_vault), 10)))
            ),
            false,
            keccak256(abi.encode(d))
        );
        _token.pause();
        _mintAccrued(1);
        assertEq(points.callbacks(), 2);
        assertEq(points.rejectedAttacks(), 2);
        assertEq(points.firstRawSupply(), 10);
        assertEq(points.lastRawSupply(), 13);
        assertEq(_token.totalSupply(), 13);
    }

    /// @dev Each target receives the role/allowance needed to reach the batch guard; an access
    ///      failure or an ignored points revert does not count as a successfully blocked attack.
    function test_pointsCannotMutateTokenAllowanceRolesModulesPauseOrUpgrade() public {
        _bind();
        _ordinaryMint(address(_vault), 100);
        USDfrAccrualPoints points = _points();
        _token.grantRole(bytes32(0), address(points));
        _token.grantRole(Roles.MINTER_ROLE, address(points));
        _token.grantRole(Roles.GUARDIAN_ROLE, address(points));
        _token.grantRole(Roles.UPGRADER_ROLE, address(points));
        vm.prank(address(_vault));
        _token.approve(address(points), type(uint256).max);
        bytes[] memory attacks = new bytes[](16);
        attacks[0] = abi.encodeCall(USDfr.mint, (address(_vault), 10));
        attacks[1] = abi.encodeCall(USDfr.burn, (address(_vault), 1));
        attacks[2] = abi.encodeWithSignature("transfer(address,uint256)", HOLDER, 0);
        attacks[3] = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(_vault), HOLDER, 1);
        attacks[4] = abi.encodeWithSignature("approve(address,uint256)", HOLDER, 1);
        attacks[5] = abi.encodeWithSignature("grantRole(bytes32,address)", Roles.MINTER_ROLE, HOLDER);
        attacks[6] = abi.encodeWithSignature("revokeRole(bytes32,address)", Roles.MINTER_ROLE, address(_controller));
        attacks[7] = abi.encodeWithSignature("renounceRole(bytes32,address)", Roles.MINTER_ROLE, address(points));
        attacks[8] = abi.encodeCall(USDfr.setComplianceModule, (address(0)));
        attacks[9] = abi.encodeCall(USDfr.setPointsModule, (address(0)));
        attacks[10] = abi.encodeCall(USDfr.setAccrualReserve, (address(_reserve)));
        attacks[11] = abi.encodeCall(USDfr.pause, ());
        attacks[12] = abi.encodeCall(USDfr.unpause, ());
        attacks[13] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(new USDfr()), bytes(""));
        attacks[14] = abi.encodeCall(USDfr.mintAccrued, (1));
        attacks[15] = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(_vault), HOLDER, 0);
        for (uint256 i; i < attacks.length; ++i) {
            IContinuousAccrual.Delivery memory d = _delivery(i + 1, 10, 3, 3);
            _setDelivery(d);
            points.configure(address(_token), attacks[i], false, keccak256(abi.encode(d)));
            _mintAccrued(i + 1);
            assertEq(points.callbacks(), 2, "points revert must not mask a failed assertion");
            assertEq(points.rejectedAttacks(), 2, "both legs must actually execute the attack");
            assertEq(_token.totalSupply(), 100 + (i + 1) * 13);
        }
        assertEq(_token.allowance(address(_vault), address(points)), type(uint256).max);
        assertTrue(_token.hasRole(Roles.MINTER_ROLE, address(_controller)));
        assertFalse(_token.hasRole(Roles.MINTER_ROLE, HOLDER));
        assertFalse(_token.paused());
    }

    function test_pointsFiniteAllowanceWriteCannotRunDuringDelivery() public {
        _bind();
        _ordinaryMint(address(_vault), 10);
        USDfrAccrualPoints points = _points();
        vm.prank(address(_vault));
        _token.approve(address(points), 9);
        _setDelivery(_delivery(1, 10, 0, 1));
        points.configure(
            address(_token),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(_vault), HOLDER, 1),
            false,
            bytes32(0)
        );
        _mintAccrued(1);
        assertEq(points.rejectedAttacks(), 1);
        assertEq(_token.allowance(address(_vault), address(points)), 9);
    }

    function test_validSignedPermitCannotConsumeNonceInEitherCallback() public {
        _bind();
        uint256 key = 0xace;
        address owner = vm.addr(key);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                HOLDER,
                7,
                0,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", _token.DOMAIN_SEPARATOR(), structHash)));
        bytes memory attack = abi.encodeWithSignature(
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)", owner, HOLDER, 7, deadline, v, r, s
        );
        USDfrAccrualCompliance compliance = new USDfrAccrualCompliance();
        _token.setComplianceModule(address(compliance));
        compliance.configureAttack(address(_token), attack, true);
        USDfrAccrualPoints points = _points();
        points.configure(address(_token), attack, false, bytes32(0));
        _setDelivery(_delivery(1, 10, 3, 3));
        _mintAccrued(1);
        assertEq(points.rejectedAttacks(), 2);
        assertEq(_token.nonces(owner), 0);
        assertEq(_token.allowance(owner, HOLDER), 0);
        _token.permit(owner, HOLDER, 7, deadline, v, r, s);
        assertEq(_token.nonces(owner), 1);
        assertEq(_token.allowance(owner, HOLDER), 7);
    }

    /// @dev The ordinary 100k points epilogue reserve is insufficient for a second leg's
    ///      500k hook floor. Both callbacks deliberately exhaust all forwarded gas here.
    function test_twoLegDeliverySurvivesGasExhaustionByBothPointsHooks() public {
        _bind();
        _token.setPointsModule(address(new USDfrAccrualExhaustingPoints()));
        _setDelivery(_delivery(1, 10, 3, 3));
        vm.expectEmit(true, true, false, true, address(_token));
        emit Transfer(address(0), address(_vault), 10);
        vm.expectEmit(true, true, false, true, address(_token));
        emit PointsHookFailed(address(0), address(_vault), 10);
        vm.expectEmit(true, true, false, true, address(_token));
        emit Transfer(address(0), FEE_RECIPIENT, 3);
        vm.expectEmit(true, true, false, true, address(_token));
        emit PointsHookFailed(address(0), FEE_RECIPIENT, 3);
        _controller.relay{gas: 2_000_000}(address(_token), abi.encodeCall(USDfr.mintAccrued, (1)));
        assertEq(_token.totalSupply(), 13);
        assertEq(_token.balanceOf(address(_vault)), 10);
        assertEq(_token.balanceOf(FEE_RECIPIENT), 3);
    }

    function test_twoLegHookBudgetCannotBeUnderfundedAsIfItWereOneLeg() public {
        _bind();
        _points();
        _setDelivery(_delivery(1, 10, 3, 3));
        (bool ok, bytes memory result) = address(_controller).call{gas: 950_000}(
            abi.encodeCall(USDfrAccrualEndpoint.relay, (address(_token), abi.encodeCall(USDfr.mintAccrued, (1))))
        );
        assertFalse(ok);
        assertGe(result.length, 4);
        assertEq(bytes4(result), PointsHook_InsufficientGas.selector);
        assertEq(_token.totalSupply(), 0);
        _mintAccrued(1);
        assertEq(_token.totalSupply(), 13);
    }

    function test_pointsHookFailureRemainsFailOpenAndObservableForEachLeg() public {
        _bind();
        USDfrAccrualPoints points = _points();
        points.configure(address(0), bytes(""), true, bytes32(0));
        _setDelivery(_delivery(1, 10, 3, 3));
        vm.expectEmit(true, true, false, true, address(_token));
        emit Transfer(address(0), address(_vault), 10);
        vm.expectEmit(true, true, false, true, address(_token));
        emit PointsHookFailed(address(0), address(_vault), 10);
        vm.expectEmit(true, true, false, true, address(_token));
        emit Transfer(address(0), FEE_RECIPIENT, 3);
        vm.expectEmit(true, true, false, true, address(_token));
        emit PointsHookFailed(address(0), FEE_RECIPIENT, 3);
        _mintAccrued(1);
        assertEq(_token.totalSupply(), 13);
        assertEq(points.callbacks(), 0);
    }

    function test_underfundedPointsHookRollsBackDeliveryAndNonce() public {
        _bind();
        _points();
        _setDelivery(_delivery(1, 10, 3, 3));
        (bool ok, bytes memory result) = address(_controller).call{gas: 480_000}(
            abi.encodeCall(USDfrAccrualEndpoint.relay, (address(_token), abi.encodeCall(USDfr.mintAccrued, (1))))
        );
        assertFalse(ok);
        assertGe(result.length, 4);
        assertEq(bytes4(result), PointsHook_InsufficientGas.selector);
        assertEq(_token.totalSupply(), 0);
        _mintAccrued(1);
        assertEq(_token.totalSupply(), 13);
    }

    function test_mutationsRemainAvailableAfterCompletedBatch() public {
        _bind();
        _setDelivery(_delivery(1, 10, 3, 3));
        _mintAccrued(1);
        _token.approve(HOLDER, 5);
        _token.grantRole(Roles.MINTER_ROLE, HOLDER);
        _token.revokeRole(Roles.MINTER_ROLE, HOLDER);
        _token.setComplianceModule(address(0));
        _token.setPointsModule(address(0));
        _token.pause();
        _token.unpause();
        _ordinaryMint(HOLDER, 2);
        vm.prank(HOLDER);
        _token.transfer(FEE_RECIPIENT, 1);
        vm.prank(address(_controller));
        _token.burn(HOLDER, 1);
        assertEq(_token.totalSupply(), 14);
        _token.upgradeToAndCall(address(new USDfr()), bytes(""));
        assertEq(_token.accrualReserve(), address(_reserve));
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_AccrualNonceUsed.selector, 1, 1));
        _mintAccrued(1);
    }

    function test_upgradePreservesLegacySlotsBindingsBalancesAndReplayState() public {
        bytes32 slot = 0xc3fcf06498ffe1eac01a14cc645fb1e6aacc447c7b2a7d46a005df569b521500;
        USDfrAccrualCompliance compliance = new USDfrAccrualCompliance();
        _token.setComplianceModule(address(compliance));
        USDfrAccrualPoints points = _points();
        _ordinaryMint(HOLDER, 17);
        vm.prank(HOLDER);
        _token.approve(FEE_RECIPIENT, 9);
        assertEq(vm.load(address(_token), slot), bytes32(uint256(uint160(address(compliance)))));
        assertEq(vm.load(address(_token), bytes32(uint256(slot) + 1)), bytes32(uint256(uint160(address(points)))));
        _bind();
        _setDelivery(_delivery(1, 10, 3, 3));
        _mintAccrued(1);
        _token.pause();
        _token.upgradeToAndCall(address(new USDfr()), bytes(""));
        assertEq(vm.load(address(_token), slot), bytes32(uint256(uint160(address(compliance)))));
        assertEq(vm.load(address(_token), bytes32(uint256(slot) + 1)), bytes32(uint256(uint160(address(points)))));
        assertEq(_token.complianceModule(), address(compliance));
        assertEq(_token.pointsModule(), address(points));
        assertEq(_token.accrualReserve(), address(_reserve));
        assertEq(_token.totalSupply(), 30);
        assertEq(_token.balanceOf(HOLDER), 17);
        assertEq(_token.allowance(HOLDER, FEE_RECIPIENT), 9);
        assertTrue(_token.paused());
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_AccrualNonceUsed.selector, 1, 1));
        _mintAccrued(1);
        _setDelivery(_delivery(2, 10, 3, 3));
        _mintAccrued(2); // All pinned identities and the cleared delivery guard remain usable.
        assertEq(_token.totalSupply(), 43);
    }

    function _modules() private view returns (IContinuousAccrual.Modules memory) {
        return IContinuousAccrual.Modules(
            address(_token), address(_controller), address(_vault), address(0), address(0), address(0), address(0)
        );
    }

    function _validModuleReplies() private {
        _reserve.setReply(MODULES, abi.encode(_modules()));
        _controller.setReply(
            IMintRedeemController.modules.selector, abi.encode(address(_token), address(0), address(_reserve))
        );
        _vault.setReply(IERC4626.asset.selector, abi.encode(address(_token)));
    }

    function _invalidModules(IContinuousAccrual.Modules memory m) private {
        _reserve.setReply(MODULES, abi.encode(m));
        _expectInvalidReserve(address(_reserve));
    }

    function _expectInvalidReserve(address reserve) private {
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_InvalidAccrualReserve.selector, reserve));
        _token.setAccrualReserve(reserve);
        assertEq(_token.accrualReserve(), address(0));
    }

    function _bind() private {
        _token.setAccrualReserve(address(_reserve));
    }

    function _delivery(uint256 nonce, uint256 senior, uint256 fee, uint8 legs)
        private
        view
        returns (IContinuousAccrual.Delivery memory d)
    {
        d.nonce = nonce;
        d.senior = senior;
        d.fee = fee;
        d.effectiveSupply = _token.totalSupply() + senior + fee;
        d.backing = d.effectiveSupply;
        d.recognizedBacking = d.effectiveSupply;
        d.pricing = IContinuousAccrual.PricingState(senior, senior, senior, senior, 100, true);
        d.controller = address(_controller);
        d.vault = address(_vault);
        d.feeRecipient = FEE_RECIPIENT;
        d.accruedThrough = uint64(block.timestamp);
        d.legs = legs;
        d.active = true;
    }

    function _setDelivery(IContinuousAccrual.Delivery memory d) private {
        _reserve.setReply(DELIVERY, abi.encode(d));
    }

    function _mintAccrued(uint256 nonce) private {
        vm.prank(address(_controller));
        _token.mintAccrued(nonce);
    }

    function _ordinaryMint(address to, uint256 amount) private {
        vm.prank(address(_controller));
        _token.mint(to, amount);
    }

    function _expectInvalidDelivery(uint256 nonce) private {
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_InvalidAccrualDelivery.selector, nonce));
        _mintAccrued(nonce);
    }

    function _points() private returns (USDfrAccrualPoints points) {
        points = new USDfrAccrualPoints(_token, IContinuousAccrual(address(_reserve)));
        _token.setPointsModule(address(points));
    }
}
