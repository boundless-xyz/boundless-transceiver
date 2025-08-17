// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IRiscZeroVerifier } from "@risc0/contracts/IRiscZeroVerifier.sol";
import { ConsensusState, Checkpoint } from "./tseth.sol";
import { IWormhole } from "wormhole-sdk/interfaces/IWormhole.sol";
import { toWormholeFormat } from "wormhole-sdk/Utils.sol";
import { Beacon } from "./lib/Beacon.sol";

contract BoundlessReceiver is AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant UNDEFINED_ROOT = bytes32(0);

    uint16 public constant BOUNDLESS_FLAG = 0;
    uint16 public constant WORMHOLE_FLAG = 1;
    uint16 public constant TWO_OF_TWO_FLAG = BOUNDLESS_FLAG | WORMHOLE_FLAG;

    struct CheckpointAttestation {
        uint16 confirmations;
    }

    struct Journal {
        ConsensusState preState;
        ConsensusState postState;
    }

    ConsensusState private currentState;

    bytes32 public imageID;

    IWormhole public immutable WORMHOLE;

    /// @notice The address of the approved BeaconEmitter contract deployment
    bytes32 public immutable BEACON_EMITTER;

    address public immutable VERIFIER;

    uint24 public permissibleTimespan;

    /// @notice The chain ID where the approved BeaconEmitter is deployed.
    uint16 public immutable EMITTER_CHAIN_ID;

    mapping(uint64 slot => bytes32 blockRoot) private roots;
    mapping(bytes32 checkpointHash => CheckpointAttestation attestation) private attestations;

    event Transitioned(
        uint64 indexed preEpoch, uint64 indexed postEpoch, ConsensusState preState, ConsensusState postState
    );
    event Confirmed(uint64 indexed slot, bytes32 indexed root, uint16 indexed confirmationLevel);

    error InvalidArgument();
    error InvalidPreState();
    error PermissibleTimespanLapsed();
    error UnauthorizedEmitterChainId();
    error UnauthorizedEmitterAddress();

    constructor(
        ConsensusState memory startingState,
        uint24 permissibleTimespan_,
        address verifier,
        bytes32 imageID_,
        address wormhole,
        address beaconEmitter,
        uint16 emitterChainId,
        address admin,
        address roleAdmin
    ) {
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(DEFAULT_ADMIN_ROLE, roleAdmin);

        currentState = startingState;
        permissibleTimespan = permissibleTimespan_;
        imageID = imageID_;
        VERIFIER = verifier;
        WORMHOLE = IWormhole(wormhole);
        BEACON_EMITTER = toWormholeFormat(beaconEmitter);
        EMITTER_CHAIN_ID = emitterChainId;
    }

    function transition(bytes calldata journalData, bytes calldata seal, uint64 finalizedSlot) external {
        Journal memory journal = abi.decode(journalData, (Journal));
        if (!_compareConsensusState(currentState, journal.preState)) {
            revert InvalidPreState();
        }
        if (!_permissibleTransition(journal.preState, journal.postState)) {
            revert PermissibleTimespanLapsed();
        }

        bytes32 journalHash = sha256(journalData);
        IRiscZeroVerifier(VERIFIER).verify(seal, imageID, journalHash);

        _transition(journal, finalizedSlot);
    }

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

    function manualTransition(bytes calldata journalData, uint64 finalizedSlot) external onlyRole(ADMIN_ROLE) {
        Journal memory journal = abi.decode(journalData, (Journal));
        _transition(journal, finalizedSlot);
    }

    /**
     * @notice the root associated with the provided `slot`. If the confirmation level isn't met or the root is not
     * set, `valid` will be false
     *
     * TODO: Add in link ref to confirmation levels
     *
     * @param slot the beacon chain slot to look up
     * @param confirmationLevel the level of confirmations required for `valid` to be `true`
     */
    function blockRoot(uint64 slot, uint16 confirmationLevel) external view returns (bytes32 root, bool valid) {
        root = roots[slot];
        if (root == UNDEFINED_ROOT) {
            valid = false;
        }
        CheckpointAttestation storage attestation = attestations[_checkpointHash(slot, root)];
        valid = _sufficientConfirmations(attestation.confirmations, confirmationLevel);
    }

    function updateImageID(bytes32 newImageID) external onlyRole(ADMIN_ROLE) {
        if (newImageID == imageID) revert InvalidArgument();
        imageID = newImageID;
    }

    function updatePermissibleTimespan(uint24 newPermissibleTimespan) external onlyRole(ADMIN_ROLE) {
        if (newPermissibleTimespan == permissibleTimespan) {
            revert InvalidArgument();
        }
        permissibleTimespan = newPermissibleTimespan;
    }

    function _transition(Journal memory journal, uint64 finalizedSlot) internal {
        currentState = journal.postState;
        emit Transitioned(
            journal.preState.finalizedCheckpoint.epoch,
            journal.postState.finalizedCheckpoint.epoch,
            journal.preState,
            journal.postState
        );

        Checkpoint memory finalizedCheckpoint = journal.postState.finalizedCheckpoint;
        _confirm(finalizedSlot, finalizedCheckpoint.root, BOUNDLESS_FLAG);
    }

    function _compareConsensusState(ConsensusState memory a, ConsensusState memory b) internal pure returns (bool) {
        return _compareCheckpoint(a.currentJustifiedCheckpoint, b.currentJustifiedCheckpoint)
            && _compareCheckpoint(a.finalizedCheckpoint, b.finalizedCheckpoint);
    }

    function _compareCheckpoint(Checkpoint memory a, Checkpoint memory b) internal pure returns (bool) {
        return a.epoch == b.epoch && a.root == b.root;
    }

    function _permissibleTransition(
        ConsensusState memory pre,
        ConsensusState memory post
    )
        internal
        view
        returns (bool)
    {
        uint256 transitionTimespan = block.timestamp
            - Beacon.epochTimestamp(Beacon.ETHEREUM_GENESIS_BEACON_BLOCK_TIMESTAMP, post.finalizedCheckpoint.epoch);
        return transitionTimespan <= uint256(permissibleTimespan);
    }

    // @notice Generates a unique hash for block that was included in the chain at the given slot
    function _checkpointHash(uint64 slot, bytes32 root) internal pure returns (bytes32 hash) {
        hash = keccak256(abi.encodePacked(slot, root));
    }

    function _confirm(uint64 slot, bytes32 root, uint16 flag) internal {
        CheckpointAttestation storage attestation = attestations[_checkpointHash(slot, root)];
        attestation.confirmations = _confirm(attestation.confirmations, flag);
        // TODO: Verify if blockroot collision is possible
        if (roots[slot] == UNDEFINED_ROOT) {
            roots[slot] = root;
        }
        emit Confirmed(slot, root, attestation.confirmations);
    }

    function _confirm(uint16 confirmations, uint16 flag) internal pure returns (uint16) {
        return uint16(confirmations | (1 << flag));
    }

    function _sufficientConfirmations(uint16 confirmations, uint16 targetLevel) internal pure returns (bool) {
        uint16 remainder = confirmations & targetLevel;
        return remainder >= targetLevel;
    }
}
