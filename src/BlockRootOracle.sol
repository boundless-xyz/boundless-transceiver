// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IRiscZeroVerifier } from "@risc0/contracts/IRiscZeroVerifier.sol";
import { ConsensusState, Checkpoint } from "./tseth.sol";
import { IWormhole } from "wormhole-solidity-sdk/interfaces/IWormhole.sol";
import { toWormholeFormat } from "wormhole-solidity-sdk/Utils.sol";
import { Beacon } from "./lib/Beacon.sol";
import { Steel, Encoding as SteelEncoding } from "@risc0/contracts/steel/Steel.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ICommitmentValidator } from "./interfaces/ICommitmentValidator.sol";

uint16 constant BOUNDLESS_FLAG = 0;
uint16 constant WORMHOLE_FLAG = 1;
uint16 constant TWO_OF_TWO_FLAG = uint16((1 << BOUNDLESS_FLAG) | (1 << WORMHOLE_FLAG));

contract BlockRootOracle is AccessControl, ICommitmentValidator {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant UNDEFINED_ROOT = bytes32(0);

    /// @notice Tracks confirmation status for beacon chain checkpoints
    /// @dev Used to determine the level of validation for a given checkpoint
    struct CheckpointAttestation {
        /// @dev Bitwise flags indicating confirmation sources (Boundless=1, Wormhole=2)
        uint16 confirmations;
    }

    /// @notice Contains the complete state transition data for verification
    /// @dev Used as journal data in RISC Zero proofs to validate beacon state transitions
    struct Journal {
        /// @dev The consensus state before the transition
        ConsensusState preState;
        /// @dev The consensus state after the transition
        ConsensusState postState;
        /// @dev The beacon chain slot that was finalized in this transition
        uint64 finalizedSlot;
    }

    /// @notice The current consensus state of the beacon chain
    /// @dev Updated atomically through state transitions to ensure consistency
    ConsensusState private currentState;

    bytes32 public imageID;

    IWormhole public immutable WORMHOLE;

    /// @notice The address of the approved BeaconEmitter contract deployment
    /// @dev Wormhole-formatted address of the BeaconEmitter contract that is authorized to emit beacon state messages
    bytes32 public immutable BEACON_EMITTER;

    /// @notice The address of the RISC Zero verifier contract
    /// @dev Used to validate zero-knowledge proofs of beacon state transitions
    address public immutable VERIFIER;

    /// @notice Maximum allowed time span for state transitions in seconds
    /// @dev Used to prevent acceptance of stale beacon state transitions
    uint24 public permissibleTimespan;

    /// @notice The chain ID where the approved BeaconEmitter is deployed.
    uint16 public immutable EMITTER_CHAIN_ID;

    Beacon.BeaconConfig private BEACON_CONFIG;

    mapping(uint64 slot => bytes32 blockRoot) private roots;
    mapping(bytes32 checkpointHash => CheckpointAttestation attestation) private attestations;

    event Transitioned(
        uint64 indexed preEpoch, uint64 indexed postEpoch, ConsensusState preState, ConsensusState postState
    );
    event Confirmed(uint64 indexed slot, bytes32 indexed root, uint16 indexed confirmationLevel);
    event ImageIDUpdated(bytes32 indexed newImageID, bytes32 indexed oldImageID);
    event PermissibleTimespanUpdated(uint24 indexed permissibleTimespan);

    error InvalidArgument();
    error InvalidPreState();
    error PermissibleTimespanLapsed();
    error UnauthorizedEmitterChainId();
    error UnauthorizedEmitterAddress();

    /// @notice Initializes the BoundlessReceiver contract with all required parameters
    /// @dev Sets up the initial consensus state, configures verification parameters, and establishes cross-chain
    /// communication
    /// @param startingState The initial consensus state of the beacon chain
    /// @param permissibleTimespan_ Maximum allowed time span for state transitions in seconds
    /// @param verifier Address of the RISC Zero verifier contract for proof validation
    /// @param imageID_ The RISC Zero image ID for the beacon state transition program
    /// @param wormhole Address of the Wormhole core contract for cross-chain messaging
    /// @param beaconEmitter Address of the authorized BeaconEmitter contract
    /// @param emitterChainId Chain ID where the BeaconEmitter is deployed
    /// @param admin Address to be granted the ADMIN_ROLE
    /// @param superAdmin Address to be granted the DEFAULT_ADMIN_ROLE
    /// @param beaconConfig BeaconConfig for the chain of choice
    constructor(
        ConsensusState memory startingState,
        uint24 permissibleTimespan_,
        address verifier,
        bytes32 imageID_,
        address wormhole,
        address beaconEmitter,
        uint16 emitterChainId,
        address admin,
        address superAdmin,
        Beacon.BeaconConfig memory beaconConfig
    ) {
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(DEFAULT_ADMIN_ROLE, superAdmin);

        currentState = startingState;
        permissibleTimespan = permissibleTimespan_;
        imageID = imageID_;
        VERIFIER = verifier;
        WORMHOLE = IWormhole(wormhole);
        BEACON_EMITTER = toWormholeFormat(beaconEmitter);
        EMITTER_CHAIN_ID = emitterChainId;
        BEACON_CONFIG = beaconConfig;
    }

    /// @notice Validates and applies a beacon state transition using RISC Zero proof
    /// @dev Verifies the transition proof, checks pre-state consistency, and applies the new state
    /// @param journalData Encoded Journal struct containing pre/post states and finalized slot
    /// @param seal RISC Zero cryptographic proof validating the state transition
    function transition(bytes calldata journalData, bytes calldata seal) external {
        Journal memory journal = abi.decode(journalData, (Journal));
        if (!_compareConsensusState(currentState, journal.preState)) {
            revert InvalidPreState();
        }
        if (!_permissibleTransition(journal.preState)) {
            revert PermissibleTimespanLapsed();
        }

        bytes32 journalHash = sha256(journalData);
        IRiscZeroVerifier(VERIFIER).verify(seal, imageID, journalHash);

        _transition(journal);
    }

    /// @notice Processes beacon state messages received via Wormhole
    /// @dev Validates the Wormhole message and confirms beacon chain checkpoints
    /// @param encodedVM Encoded Wormhole virtual machine message containing beacon data
    function receiveWormholeMessage(bytes calldata encodedVM) external {
        (IWormhole.VM memory vm, bool valid, string memory reason) = WORMHOLE.parseAndVerifyVM(encodedVM);
        if (!valid) {
            revert(reason);
        }
        if (vm.emitterChainId != EMITTER_CHAIN_ID) {
            revert UnauthorizedEmitterChainId();
        }
        if (vm.emitterAddress != BEACON_EMITTER) {
            revert UnauthorizedEmitterAddress();
        }

        (uint64 slot, bytes32 root) = abi.decode(vm.payload, (uint64, bytes32));

        _confirm(slot, root, WORMHOLE_FLAG);
    }

    /// @notice Manually applies a beacon state transition without proof verification
    /// @dev Admin-only function for emergency state updates or testing purposes
    /// @param journalData Encoded Journal struct containing pre/post states and finalized slot
    function manualTransition(bytes calldata journalData) external onlyRole(ADMIN_ROLE) {
        Journal memory journal = abi.decode(journalData, (Journal));
        _transition(journal);
    }

    /// @notice the root associated with the provided `slot`. If the confirmation level isn't met or the root is not
    /// set, `valid` will be false
    /// @param slot the beacon chain slot to look up
    /// @param confirmationLevel the level of confirmations required for `valid` to be `true`
    function blockRoot(uint64 slot, uint16 confirmationLevel) public view returns (bytes32 root, bool valid) {
        root = roots[slot];
        if (root == UNDEFINED_ROOT) {
            valid = false;
        }
        CheckpointAttestation memory attestation = attestations[_checkpointHash(slot, root)];
        valid = _sufficientConfirmations(attestation.confirmations, confirmationLevel);
    }

    function updateImageID(bytes32 newImageID) external onlyRole(ADMIN_ROLE) {
        if (newImageID == imageID) revert InvalidArgument();

        emit ImageIDUpdated(newImageID, imageID);
        imageID = newImageID;
    }

    function updatePermissibleTimespan(uint24 newPermissibleTimespan) external onlyRole(ADMIN_ROLE) {
        if (newPermissibleTimespan == permissibleTimespan) {
            revert InvalidArgument();
        }
        permissibleTimespan = newPermissibleTimespan;
        emit PermissibleTimespanUpdated(newPermissibleTimespan);
    }

    /// @notice Internal function to apply a validated state transition
    /// @dev Updates the current state, emits Transitioned event, and confirms the finalized checkpoint
    /// @param journal The journal containing the state transition data
    function _transition(Journal memory journal) internal {
        currentState = journal.postState;
        emit Transitioned(
            journal.preState.finalizedCheckpoint.epoch,
            journal.postState.finalizedCheckpoint.epoch,
            journal.preState,
            journal.postState
        );

        Checkpoint memory finalizedCheckpoint = journal.postState.finalizedCheckpoint;
        _confirm(journal.finalizedSlot, finalizedCheckpoint.root, BOUNDLESS_FLAG);
    }

    /// @notice Compare two ConsensusState structures for equality
    /// @dev Checks if both currentJustifiedCheckpoint and finalizedCheckpoint match
    /// @param a First ConsensusState to compare
    /// @param b Second ConsensusState to compare
    /// @return Whether the two ConsensusState structures are equal
    function _compareConsensusState(ConsensusState memory a, ConsensusState memory b) internal pure returns (bool) {
        return _compareCheckpoint(a.currentJustifiedCheckpoint, b.currentJustifiedCheckpoint)
            && _compareCheckpoint(a.finalizedCheckpoint, b.finalizedCheckpoint);
    }

    /// @notice Compare two Checkpoint structures for equality
    /// @dev Checks if both epoch and root match
    /// @param a First Checkpoint to compare
    /// @param b Second Checkpoint to compare
    /// @return Whether the two Checkpoint structures are equal
    function _compareCheckpoint(Checkpoint memory a, Checkpoint memory b) internal pure returns (bool) {
        return a.epoch == b.epoch && a.root == b.root;
    }

    /// @notice Check if a transition is within the permissible timespan
    /// @dev Ensures that the transition is not too old based on the permissibleTimespan setting
    /// @param state The consensus state to check
    /// @return Whether the transition is within the permissible timespan
    function _permissibleTransition(ConsensusState memory state) internal view returns (bool) {
        uint256 transitionTimespan =
            block.timestamp - Beacon.epochTimestamp(state.finalizedCheckpoint.epoch, BEACON_CONFIG);
        return transitionTimespan <= uint256(permissibleTimespan);
    }

    /// @notice Generates a unique hash for a checkpoint at a given slot
    /// @dev Creates a unique identifier for block that was included in the chain at the given slot
    /// @param slot The slot number
    /// @param root The block root
    /// @return hash The unique hash for the checkpoint
    function _checkpointHash(uint64 slot, bytes32 root) internal pure returns (bytes32 hash) {
        hash = keccak256(abi.encodePacked(slot, root));
    }

    /// @notice Confirm a checkpoint with a specific flag
    /// @dev Updates the attestation confirmations and stores the root if not already present
    /// @param slot The slot number
    /// @param root The block root
    /// @param flag The confirmation flag to set
    function _confirm(uint64 slot, bytes32 root, uint16 flag) internal {
        CheckpointAttestation storage attestation = attestations[_checkpointHash(slot, root)];
        attestation.confirmations = _confirm(attestation.confirmations, flag);
        // TODO: Verify if blockroot collision is possible
        if (roots[slot] == UNDEFINED_ROOT) {
            roots[slot] = root;
        }
        emit Confirmed(slot, root, attestation.confirmations);
    }

    /// @notice Set a confirmation flag in the confirmations bitmask
    /// @dev Uses bitwise OR to set the specified flag
    /// @param confirmations The current confirmations bitmask
    /// @param flag The flag to set
    /// @return The updated confirmations bitmask
    function _confirm(uint16 confirmations, uint16 flag) internal pure returns (uint16) {
        return uint16(confirmations | (1 << flag));
    }

    /// @notice Check if confirmations meet the target level
    /// @dev Uses bitwise AND to check if all required confirmations are present
    /// @param confirmations The current confirmations bitmask
    /// @param targetLevel The target confirmation level
    /// @return Whether the confirmations meet the target level
    function _sufficientConfirmations(uint16 confirmations, uint16 targetLevel) internal pure returns (bool) {
        uint16 remainder = confirmations & targetLevel;
        return remainder == targetLevel;
    }

    /// @inheritdoc ICommitmentValidator
    function validateCommitment(
        Steel.Commitment memory commitment,
        uint16 confirmationLevel
    )
        external
        view
        returns (bool)
    {
        (uint240 blockId, uint16 version) = SteelEncoding.decodeVersionedID(commitment.id);
        if (version != 2) {
            revert Steel.InvalidCommitmentVersion();
        }

        return validateReceiverCommitment(SafeCast.toUint64(blockId), commitment.digest, confirmationLevel);
    }

    /// @notice Validates commitment against the BoundlessReceiver contract
    /// @param slot The timestamp indicating the beacon block root the commitment is associated with
    /// @param expectedBlockRoot The expected parent beacon block root
    /// @param confirmationLevel A flag indicating required level of confirmation the block root must meet
    /// @return True if the commitment is valid
    function validateReceiverCommitment(
        uint64 slot,
        bytes32 expectedBlockRoot,
        uint16 confirmationLevel
    )
        internal
        view
        returns (bool)
    {
        (bytes32 root, bool valid) = blockRoot(slot, confirmationLevel);
        return valid && (root == expectedBlockRoot);
    }
}
