// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @dev Minimal six-decimal token model at the protocol trust boundary. The proof executes
///      the real ReserveManager transfer/accounting code; this model supplies only standard,
///      exact ERC-20 balance and allowance semantics.
contract SymbolicUSDC {
    uint8 public constant decimals = 6;

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            uint256 permitted = allowance[from][msg.sender];
            require(permitted >= amount, "ALLOWANCE");
            if (permitted != type(uint256).max) allowance[from][msg.sender] = permitted - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        uint256 balance = balanceOf[from];
        require(balance >= amount, "BALANCE");
        balanceOf[from] = balance - amount;
        balanceOf[to] += amount;
    }
}

/// @dev Minimal USDfr model at the controller trust boundary. Deployment validation and the
///      USDfr unit suite independently prove that the controller is the sole production minter.
contract SymbolicUSDfr {
    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;

    function setState(address holder, uint256 supply) external {
        totalSupply = supply;
        balanceOf[holder] = supply;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        uint256 balance = balanceOf[from];
        require(balance >= amount, "BALANCE");
        balanceOf[from] = balance - amount;
        totalSupply -= amount;
    }
}

contract SymbolicCompliance {
    function isAllowed(address) external pure returns (bool) {
        return true;
    }
}

/// @title Symbolic backing preservation against the real accounting contracts
/// @notice Halmos proves the post-state backing inequality for every input satisfying each
///         covered production transition's preconditions. The principal proofs execute the
///         shipped MintRedeemController and ReserveManager implementations through ERC-1967
///         proxies, including their checks, six-to-eighteen decimal normalization, storage
///         writes, and cross-contract calls. A separate full-domain algebraic lemma covers the
///         equal-delta identity used by the user mint/redeem transfer paths without asking the
///         solver to reason through SafeERC20 allowance plumbing.
///
///         Trust boundary: canonical USDC and USDfr are represented by exact minimal ERC-20
///         models. That is deliberate: the accounting proof is about protocol state transitions,
///         while token role topology and token behavior are covered by deployment validation,
///         unit tests, fork tests, and stateful invariants. See docs/formal-methods-amenability.md.
///
///         Run from contracts/: `halmos --match-contract BackingSymbolic`.
contract BackingSymbolic is Test {
    uint256 private constant SCALE = 1e12;

    SymbolicUSDC private usdc;
    SymbolicUSDfr private usdfr;
    ReserveManager private reserves;
    MintRedeemController private controller;

    function setUp() public {
        usdc = new SymbolicUSDC();
        usdfr = new SymbolicUSDfr();
        SymbolicCompliance compliance = new SymbolicCompliance();

        ReserveManager reserveImplementation = new ReserveManager();
        reserves = ReserveManager(
            address(
                new ERC1967Proxy(
                    address(reserveImplementation),
                    abi.encodeCall(
                        ReserveManager.initialize,
                        (address(this), address(this), address(this), address(this), address(usdc))
                    )
                )
            )
        );

        MintRedeemController controllerImplementation = new MintRedeemController();
        controller = MintRedeemController(
            address(
                new ERC1967Proxy(
                    address(controllerImplementation),
                    abi.encodeCall(
                        MintRedeemController.initialize,
                        (
                            address(this),
                            address(this),
                            address(this),
                            address(usdfr),
                            address(compliance),
                            address(reserves)
                        )
                    )
                )
            )
        );

        reserves.grantRole(Roles.CONTROLLER_ROLE, address(controller));
        reserves.grantRole(Roles.CREDIT_ROLE, address(this));
        controller.grantRole(Roles.CREDIT_ROLE, address(this));
    }

    /// @notice Full-domain induction lemma for user mint and redeem. Both real controller
    ///         paths add or subtract the same exact normalized value on each side; their unit,
    ///         fork, and differential invariant tests bind that implementation fact to this
    ///         universally quantified arithmetic result.
    function check_equalSupplyAndBackingDeltasPreserveInvariant(
        uint256 supply,
        uint256 backing,
        uint256 increase,
        uint256 decrease
    ) public pure {
        vm.assume(supply <= backing);
        vm.assume(increase <= type(uint256).max - backing);

        supply += increase;
        backing += increase;
        assert(supply <= backing);

        vm.assume(decrease <= supply);
        vm.assume(decrease <= backing);
        supply -= decrease;
        backing -= decrease;
        assert(supply <= backing);
    }

    /// @notice A loss burn can only create more backing headroom.
    function check_lossBurnPreservesBacking(uint128 initialUnits, uint256 initialSupply, uint256 amount) public {
        _seed(initialUnits, initialSupply);
        vm.assume(amount > 0);
        vm.assume(amount <= initialSupply);

        controller.burnLoss(address(this), amount);

        _assertBacking();
        assert(usdfr.totalSupply() == initialSupply - amount);
        assert(reserves.totalBackingValue() == uint256(initialUnits) * SCALE);
    }

    /// @notice Funding moves idle value to deployed value without changing backing; an OID
    ///         capitalization adds a distinct receivable while retained cash remains idle.
    function check_deploymentAndCapitalizationPreserveBacking(
        uint128 initialUnits,
        uint256 initialSupply,
        uint128 deployUnits,
        uint128 capitalizationUnits
    ) public {
        _seed(initialUnits, initialSupply);
        vm.assume(deployUnits <= initialUnits);
        vm.assume(capitalizationUnits <= initialUnits - deployUnits);

        reserves.recordDeployment(1, address(0xB0B), deployUnits);
        uint256 afterDeployment = reserves.totalBackingValue();
        assert(afterDeployment == uint256(initialUnits) * SCALE);

        if (capitalizationUnits != 0) {
            reserves.recordFeeCapitalization(1, uint256(capitalizationUnits) * SCALE);
        }

        _assertBacking();
        assert(reserves.totalBackingValue() == afterDeployment + uint256(capitalizationUnits) * SCALE);
    }

    /// @notice A repayment moves principal back to idle and adds only received interest to
    ///         backing. Minting that exact interest as yield therefore preserves the inequality.
    function check_paymentThenYieldMintPreservesBacking(
        uint128 initialUnits,
        uint256 initialSupply,
        uint128 principalUnits,
        uint128 interestUnits
    ) public {
        _seed(initialUnits, initialSupply);
        vm.assume(principalUnits > 0);
        vm.assume(principalUnits <= initialUnits);

        reserves.recordDeployment(1, address(0xB0B), principalUnits);
        uint256 paymentUnits = uint256(principalUnits) + uint256(interestUnits);
        usdc.mint(address(this), paymentUnits);
        usdc.approve(address(reserves), paymentUnits);
        reserves.recordPayment(1, address(this), paymentUnits, uint256(principalUnits) * SCALE);

        uint256 interestValue = uint256(interestUnits) * SCALE;
        if (interestValue != 0) controller.mintYield(address(this), interestValue);

        _assertBacking();
        assert(reserves.totalBackingValue() == uint256(initialUnits) * SCALE + interestValue);
        assert(usdfr.totalSupply() == initialSupply + interestValue);
    }

    /// @notice A principal write-down paired with the cascade's equal aggregate USDfr burn
    ///         reduces both sides by the same value. Capitalization seeds the real deployed
    ///         ledger without adding irrelevant symbolic ERC-20 transfer paths; the subsequent
    ///         write-down is the same production ReserveManager transition used for funded cash
    ///         principal.
    function check_writedownThenLossBurnPreservesBacking(uint128 initialUnits, uint256 initialSupply, uint128 lossUnits)
        public
    {
        _seed(initialUnits, initialSupply);
        vm.assume(lossUnits > 0);
        vm.assume(lossUnits <= initialUnits);
        uint256 lossValue = uint256(lossUnits) * SCALE;
        vm.assume(lossValue <= initialSupply);

        reserves.recordFeeCapitalization(1, lossValue);
        reserves.recordPrincipalWritedown(1, lossValue);
        controller.burnLoss(address(this), lossValue);

        _assertBacking();
        assert(reserves.totalBackingValue() == uint256(initialUnits) * SCALE);
        assert(usdfr.totalSupply() == initialSupply - lossValue);
    }

    function _seed(uint128 initialUnits, uint256 initialSupply) private {
        uint256 initialBacking = uint256(initialUnits) * SCALE;
        vm.assume(initialSupply <= initialBacking);
        if (initialUnits != 0) {
            usdc.mint(address(this), initialUnits);
            usdc.approve(address(reserves), initialUnits);
            reserves.depositUSDC(address(this), initialUnits);
        }
        usdfr.setState(address(this), initialSupply);
        _assertBacking();
    }

    function _assertBacking() private view {
        assert(usdfr.totalSupply() <= reserves.totalBackingValue());
        assert(controller.backingInvariantHolds());
        assert(reserves.idleUSDC() <= usdc.balanceOf(address(reserves)));
        assert(reserves.totalBackingValue() == reserves.idleReserve() + reserves.deployedPrincipal());
    }
}
