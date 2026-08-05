// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {Roles} from "./libraries/Roles.sol";

/// @title RecoveryTopUpDistributor — separately funded, discretionary post-recovery payments
/// @notice Governance may fund a Merkle distribution for accounts whose queue redemptions settled
///         below realized NAV and for whom later workout proceeds justify a discretionary top-up.
///         A leaf is bound to this chain, this distributor, the round, the queue request ID, the
///         recipient, and the amount. Anyone may relay a valid claim, but funds always go directly
///         to the leaf's recipient.
///
///         This contract does NOT create an entitlement, withdraw from sUSDfr, or mint USDfr.
///         Every round is fully and separately funded up front. That separation is load-bearing:
///         recovery principal cannot simply be minted again, and taking the top-up directly from
///         the vault would otherwise shift value from current holders without an explicit decision.
/// @dev The Merkle root and evidence hash make the off-chain calculation auditable. The operational
///      calculation should cap every address/request at its documented settlement discount and
///      exclude any amount already paid in an earlier round.
contract RecoveryTopUpDistributor is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    struct Round {
        bytes32 merkleRoot;
        bytes32 evidenceHash;
        address refundRecipient;
        uint64 claimDeadline;
        uint256 funded;
        uint256 claimed;
        bool reclaimed;
    }

    /// @custom:storage-location erc7201:forestroad.storage.RecoveryTopUpDistributor
    struct DistributorStorage {
        IERC20 usdfr;
        uint256 nextRoundId;
        mapping(uint256 roundId => Round) rounds;
        mapping(uint256 roundId => mapping(uint256 wordIndex => uint256 claimedWord)) claimedBitMap;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.RecoveryTopUpDistributor")) - 1))
    // & ~bytes32(uint256(0xff))
    bytes32 private constant DISTRIBUTOR_STORAGE_LOCATION =
        0x766d1e5b4c4a9feee10f19eeda7837bd901ae43d964c73e846c8ecdd9a853a00;
    // Compatibility only: this optional contract is excluded from mainnet v1, but retaining
    // the pre-fix slot fallback prevents state loss if any existing testnet proxy is upgraded.
    bytes32 private constant LEGACY_DISTRIBUTOR_STORAGE_LOCATION =
        0xb13c75e809bf77814f78f010c4d738958cc961b17d28848da2d34c825238be00;

    event RoundCreated(
        uint256 indexed roundId,
        bytes32 indexed merkleRoot,
        uint256 funded,
        uint64 claimDeadline,
        address indexed refundRecipient,
        bytes32 evidenceHash
    );
    event TopUpClaimed(
        uint256 indexed roundId, uint256 indexed index, uint256 indexed requestId, address account, uint256 amount
    );
    event RoundReclaimed(uint256 indexed roundId, address indexed refundRecipient, uint256 amount);

    error TopUp_ZeroAddress();
    error TopUp_ZeroAmount();
    error TopUp_ZeroRoot();
    error TopUp_ZeroEvidenceHash();
    error TopUp_BadDeadline(uint64 claimDeadline);
    error TopUp_UnknownRound(uint256 roundId);
    error TopUp_Expired(uint256 roundId, uint64 claimDeadline);
    error TopUp_NotExpired(uint256 roundId, uint64 claimDeadline);
    error TopUp_AlreadyClaimed(uint256 roundId, uint256 index);
    error TopUp_InvalidProof(uint256 roundId, uint256 index);
    error TopUp_RoundReclaimed(uint256 roundId);
    error TopUp_AllocationExceedsFunding(uint256 roundId, uint256 claimed, uint256 funded);
    error TopUp_FundingMismatch(uint256 expected, uint256 received);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the distributor.
    /// @param admin Governance timelock; creates funded rounds and reclaims expired balances.
    /// @param guardian Emergency pauser for claims.
    /// @param upgrader Upgrade authority, expected to be the governance timelock.
    /// @param usdfr_ USDfr paid to recipients.
    function initialize(address admin, address guardian, address upgrader, address usdfr_) external initializer {
        if (admin == address(0) || guardian == address(0) || upgrader == address(0) || usdfr_ == address(0)) {
            revert TopUp_ZeroAddress();
        }
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        _storage().usdfr = IERC20(usdfr_);
    }

    /// @notice Creates and fully funds a recovery top-up round.
    /// @dev The caller must approve `funded` USDfr first. A balance-delta check rejects
    ///      fee-on-transfer or otherwise non-conforming funding.
    function createRound(
        bytes32 merkleRoot,
        uint256 funded,
        uint64 claimDeadline,
        address refundRecipient,
        bytes32 evidenceHash
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant returns (uint256 roundId) {
        if (merkleRoot == bytes32(0)) revert TopUp_ZeroRoot();
        if (funded == 0) revert TopUp_ZeroAmount();
        if (refundRecipient == address(0)) revert TopUp_ZeroAddress();
        if (evidenceHash == bytes32(0)) revert TopUp_ZeroEvidenceHash();
        if (claimDeadline <= block.timestamp) revert TopUp_BadDeadline(claimDeadline);

        DistributorStorage storage $ = _storage();
        IERC20 token = $.usdfr;
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), funded);
        uint256 received = token.balanceOf(address(this)) - beforeBalance;
        if (received != funded) revert TopUp_FundingMismatch(funded, received);

        roundId = $.nextRoundId++;
        $.rounds[roundId] = Round({
            merkleRoot: merkleRoot,
            evidenceHash: evidenceHash,
            refundRecipient: refundRecipient,
            claimDeadline: claimDeadline,
            funded: funded,
            claimed: 0,
            reclaimed: false
        });
        emit RoundCreated(roundId, merkleRoot, funded, claimDeadline, refundRecipient, evidenceHash);
    }

    /// @notice Claims or relays one recovery top-up. Payment always goes to `account`.
    /// @param roundId Distribution round.
    /// @param index Unique leaf index used by the bitmap.
    /// @param requestId RedemptionQueue request the discretionary payment relates to.
    /// @param account Recipient recorded in the allocation.
    /// @param amount USDfr allocated to the recipient.
    /// @param merkleProof Proof against the round root.
    function claim(
        uint256 roundId,
        uint256 index,
        uint256 requestId,
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external nonReentrant whenNotPaused {
        if (account == address(0)) revert TopUp_ZeroAddress();
        if (amount == 0) revert TopUp_ZeroAmount();

        DistributorStorage storage $ = _storage();
        Round storage round_ = $.rounds[roundId];
        if (round_.merkleRoot == bytes32(0)) revert TopUp_UnknownRound(roundId);
        if (round_.reclaimed) revert TopUp_RoundReclaimed(roundId);
        if (block.timestamp > round_.claimDeadline) revert TopUp_Expired(roundId, round_.claimDeadline);
        if (_isClaimed($, roundId, index)) revert TopUp_AlreadyClaimed(roundId, index);

        bytes32 leaf = leafHash(roundId, index, requestId, account, amount);
        if (!MerkleProof.verifyCalldata(merkleProof, round_.merkleRoot, leaf)) {
            revert TopUp_InvalidProof(roundId, index);
        }

        uint256 newClaimed = round_.claimed + amount;
        if (newClaimed > round_.funded) {
            revert TopUp_AllocationExceedsFunding(roundId, newClaimed, round_.funded);
        }
        _setClaimed($, roundId, index);
        round_.claimed = newClaimed;
        $.usdfr.safeTransfer(account, amount);
        emit TopUpClaimed(roundId, index, requestId, account, amount);
    }

    /// @notice Returns an expired round's unclaimed balance to its recorded refund recipient.
    function reclaimExpired(uint256 roundId) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        DistributorStorage storage $ = _storage();
        Round storage round_ = $.rounds[roundId];
        if (round_.merkleRoot == bytes32(0)) revert TopUp_UnknownRound(roundId);
        if (round_.reclaimed) revert TopUp_RoundReclaimed(roundId);
        if (block.timestamp <= round_.claimDeadline) {
            revert TopUp_NotExpired(roundId, round_.claimDeadline);
        }
        round_.reclaimed = true;
        uint256 amount = round_.funded - round_.claimed;
        if (amount != 0) $.usdfr.safeTransfer(round_.refundRecipient, amount);
        emit RoundReclaimed(roundId, round_.refundRecipient, amount);
    }

    /// @notice Hashes a canonical allocation leaf, domain-separated by chain and distributor.
    function leafHash(uint256 roundId, uint256 index, uint256 requestId, address account, uint256 amount)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            bytes.concat(
                keccak256(abi.encode(block.chainid, address(this), roundId, index, requestId, account, amount))
            )
        );
    }

    /// @notice Whether an allocation index has already been paid.
    function isClaimed(uint256 roundId, uint256 index) external view returns (bool) {
        return _isClaimed(_storage(), roundId, index);
    }

    /// @notice Round metadata and accounting.
    function round(uint256 roundId) external view returns (Round memory) {
        return _storage().rounds[roundId];
    }

    /// @notice Next round identifier.
    function nextRoundId() external view returns (uint256) {
        return _storage().nextRoundId;
    }

    /// @notice Wired USDfr token.
    function usdfr() external view returns (address) {
        return address(_storage().usdfr);
    }

    /// @notice Pauses claims; funded assets remain reserved.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Resumes claims.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    function _isClaimed(DistributorStorage storage $, uint256 roundId, uint256 index) private view returns (bool) {
        uint256 wordIndex = index >> 8;
        uint256 bitIndex = index & 255;
        return ($.claimedBitMap[roundId][wordIndex] & (1 << bitIndex)) != 0;
    }

    function _setClaimed(DistributorStorage storage $, uint256 roundId, uint256 index) private {
        uint256 wordIndex = index >> 8;
        uint256 bitIndex = index & 255;
        $.claimedBitMap[roundId][wordIndex] |= 1 << bitIndex;
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private view returns (DistributorStorage storage $) {
        bytes32 slot = DISTRIBUTOR_STORAGE_LOCATION;
        bytes32 legacySlot = LEGACY_DISTRIBUTOR_STORAGE_LOCATION;
        assembly {
            // usdfr is permanently non-zero after initialization and identifies legacy state.
            if and(iszero(sload(slot)), iszero(iszero(sload(legacySlot)))) { slot := legacySlot }
            $.slot := slot
        }
    }
}
