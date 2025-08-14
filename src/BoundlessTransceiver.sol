// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import { Transceiver } from "wormhole-ntt/Transceiver/Transceiver.sol";
import { TransceiverStructs } from "wormhole-ntt/libraries/TransceiverStructs.sol";
import { toWormholeFormat } from "wormhole-solidity-sdk/Utils.sol";
import { BoundlessReceiver } from "./BoundlessReceiver.sol";
import { IRiscZeroVerifier } from "./interfaces/IRiscZeroVerifier.sol";
import { Steel, Encoding as SteelEncoding } from "@risc0/contracts/steel/Steel.sol";

contract BoundlessTransceiver is Transceiver {

    /// @dev Prefix for all TransceiverMessage payloads bytes4(keccak256("BoundlessTransceiverPayload"))
    /// @notice Magic string (constant value set by messaging provider) that idenfies the payload as an transceiver-emitted payload.
    ///         Note that this is not a security critical field and is used for convenience to identify the payload type.
    bytes4 constant BOUNDLESS_TRANSCEIVER_PAYLOAD_PREFIX = 0x1d49a45d;

    /// @notice The Risc0 verifier contract used to verify the ZK proof.
    IRiscZeroVerifier public immutable verifier;

    /// @notice The BoundlessReceiver contract that will be used to verify the block roots.
    BoundlessReceiver public immutable boundlessReceiver;

    /// @notice The BoundlessTransceiver contract deployed on Ethereum. Address(0) if this is Ethereum
    address public immutable ethereumBoundlessTransceiver;

    /// @notice The image ID of the Risc0 program used for event inclusion proofs.
    bytes32 public immutable imageID;

    /// @notice The Wormhole chain identifier of the source chain. Currently can only receive from Ethereum mainnet.
    uint16 sourceChainId = 2;

    /// @notice Journal that is committed to by the guest.
    struct Journal {
        // Commitment locks this proof to a specific block root
        // which can be verified against the BoundlessReceiver contract
        Steel.Commitment commitment;

        // The encoded TransceiverMessage that this proof commits to
        bytes encodedMessage;

        // The contract that emitted the message event
        address emitterContract;
    }

    /// @notice Emitted when a message is sent from this transceiver.
    /// @param recipientChain The chain ID of the recipient.
    /// @param encodedMessage The encoded TransceiverMessage.
    event SendTransceiverMessage(
        uint16 recipientChain, bytes encodedMessage
    );

    constructor(
        address _manager,
        address _r0Verifier,
        address _blockRootReceiver,
        bytes32 _imageID,
        address _ethereumBoundlessTransceiver
    ) Transceiver(_manager) {
        verifier = IRiscZeroVerifier(_r0Verifier);
        boundlessReceiver = BoundlessReceiver(_blockRootReceiver);
        imageID = _imageID;
        ethereumBoundlessTransceiver = _ethereumBoundlessTransceiver;
    }

    function getTransceiverType()
        external
        view
        virtual
        override
        returns (string memory)
    {
        return "boundless";
    }

    function _sendMessage(
        uint16 recipientChain,
        uint256, // deliveryPayment
        address caller,
        bytes32 recipientNttManagerAddress,
        bytes32, // refundAddress,
        TransceiverStructs.TransceiverInstruction memory, // transceiverInstruction,
        bytes memory nttManagerMessage
    ) internal override {
        assert(block.chainid == 1); // Only Ethereum supported as the sending chain

        (
            ,
            bytes memory encodedTransceiverPayload
        ) = TransceiverStructs.buildAndEncodeTransceiverMessage(
            BOUNDLESS_TRANSCEIVER_PAYLOAD_PREFIX,
            toWormholeFormat(caller),
            recipientNttManagerAddress,
            nttManagerMessage,
            new bytes(0)
        );

        // This is the event that the relayer is listening for and will build a ZK
        // proof of its inclusion in the source chain on the destination chain
        emit SendTransceiverMessage(recipientChain, encodedTransceiverPayload);
    }

    function _quoteDeliveryPrice(
        uint16, // targetChain,
        TransceiverStructs.TransceiverInstruction memory // transceiverInstruction
    ) internal pure override returns (uint256) {
        return 0; // Relayer fees are not processed at this time
    }

    /// @notice Process a message along with its ZK proof of inclusion in the origin chain
    /// @param journalData The journal data that the proof commits to
    /// @param seal The opaque ZK proof seal that allows it to be verified on-chain
    /// @dev This function verifies the ZK proof, checks the commitments, then forwards the message to the NTT Manager.
    function receiveMessage(
        bytes calldata journalData, bytes calldata seal
    ) external {
        assert(block.chainid != 1); // Can only receive on non-Ethereum chains

        Journal memory journal = abi.decode(journalData, (Journal));

        // Ensure the message came from the expected contract
        require(
            journal.emitterContract == ethereumBoundlessTransceiver,
            "Invalid emitter contract"
        );

        // parse the encoded Transceiver payload
        TransceiverStructs.TransceiverMessage memory parsedTransceiverMessage;
        TransceiverStructs.NttManagerMessage memory parsedNttManagerMessage;
        (parsedTransceiverMessage, parsedNttManagerMessage) = TransceiverStructs
            .parseTransceiverAndNttManagerMessage(BOUNDLESS_TRANSCEIVER_PAYLOAD_PREFIX, journal.encodedMessage);


        // Validate the steel commitment against a trusted beacon block root from the BoundlessReceiver
        require(validateCommitment(journal.commitment), "Invalid commitment");

        // Verify the ZK proof
        bytes32 journalHash = sha256(journalData);
        verifier.verify(seal, imageID, journalHash);

        // If all prior checks have passed we can trust the ZK proof of an event emitted on the source chain
        // was included and then finalized by the chain. It can be passed to the NTT Manager.
        _deliverToNttManager(
            sourceChainId,
            parsedTransceiverMessage.sourceNttManagerAddress,
            toWormholeFormat(nttManager),
            parsedNttManagerMessage
        );
    }

    /// @notice Validates a Steel commitment. Only supports v1 commitments which identify the beacon block root by its timestamp
    /// @param commitment The commitment to validate
    /// @return True if the commitment is valid
    function validateCommitment(Steel.Commitment memory commitment)
        internal
        view
        returns (bool)
    {
        (uint240 blockID, uint16 version) = SteelEncoding.decodeVersionedID(
            commitment.id
        );
        if (version != 1) {
            revert Steel.InvalidCommitmentVersion();
        }

        return validateReceiverCommitment(blockID, commitment.digest, boundlessReceiver.TWO_OF_TWO_FLAG());
    }

    /// @notice Validates commitment against the BoundlessReceiver contract
    /// @param timestamp The timestamp indicating the beacon block root the commitment is associated with
    /// @param parentRoot The expected parent beacon block root
    /// @param confirmationLevel A flag indicating required level of confirmation the block root must meet
    /// @return True if the commitment is valid
    function validateReceiverCommitment(
        uint256 timestamp,
        bytes32 parentRoot,
        uint16 confirmationLevel
    ) internal view returns (bool) {
        uint256 genesisTime = boundlessReceiver.GENESIS_BLOCK_TIMESTAMP();
        require(timestamp >= genesisTime);

        // Compute the slot corresponding to the commitment's timestamp
        uint64 slot = SafeCast.toUint64((timestamp - genesisTime) / boundlessReceiver.SECONDS_PER_SLOT());

        // Iterate backwards to locate the expected parent block
        while (slot > 0) {
            slot--;
            (bytes32 headerRoot, bool valid) = boundlessReceiver.blockRoot(slot, confirmationLevel);
            // Skip missed slots (empty roots)
            if (headerRoot == boundlessReceiver.UNDEFINED_ROOT()) {
                continue;
            }
            return valid && (headerRoot == parentRoot);
        }

        return false;
    }

}
