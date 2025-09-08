// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Transceiver } from "wormhole-ntt/Transceiver/Transceiver.sol";
import { ManagerBase } from "wormhole-ntt/NttManager/ManagerBase.sol";
import { ContextUpgradeable } from "wormhole-ntt/libraries/external/ContextUpgradeable.sol";
import { TransceiverStructs } from "wormhole-ntt/libraries/TransceiverStructs.sol";
import { toWormholeFormat } from "wormhole-solidity-sdk/Utils.sol";
import { TWO_OF_TWO_FLAG } from "./BlockRootOracle.sol";
import { ICommitmentValidator } from "./interfaces/ICommitmentValidator.sol";
import { IRiscZeroVerifier } from "./interfaces/IRiscZeroVerifier.sol";
import { Steel, Encoding as SteelEncoding } from "@steel/contracts/Steel.sol";

/// @dev Prefix for all TransceiverMessage payloads bytes4(keccak256("BoundlessTransceiverPayload"))
bytes4 constant BOUNDLESS_TRANSCEIVER_PAYLOAD_PREFIX = 0x1d49a45d;

contract BoundlessTransceiver is Transceiver {

    /// @notice The Risc0 verifier contract used to verify the ZK proof.
    IRiscZeroVerifier public verifier;

    /// @notice Struct representing a record of a supported source chain that this
    /// @notice transceiver knows how to validate commitments and event inclusions from
    struct AuthorizedSource {
        /// Wormhole formatted address of the transceiver contract on the source chain (that emits the messages)
        bytes32 transceiverContract;
        /// Contract on this chain that can validate Steel commitments from the source chain
        address commitmentValidator;
        /// Image ID for the program to prove deposit events into the transceiver on this source
        bytes32 imageID;
    }

    /// @notice Map from [Wormhole chain ID](https://wormhole.com/docs/products/reference/chain-ids/)
    /// @notice to contract that will be used to verify the Steel commitments from the foreign chain.
    mapping(uint16 => AuthorizedSource) public authorizedSources;

    /// @notice Journal that is committed to by the guest.
    struct Journal {
        // Commitment locks this proof to a specific block root
        // which can be verified against the blockRootOracle contract
        Steel.Commitment commitment;
        // The encoded TransceiverMessage that this proof commits to
        bytes encodedMessage;
        // Wormhole formatted address of the contract that emitted the message event
        bytes32 emitterContract;
    }

    /// @notice Emitted when a message is sent from this transceiver.
    /// @param recipientChain The chain ID of the recipient.
    /// @param encodedMessage The encoded TransceiverMessage.
    event SendTransceiverMessage(uint16 indexed recipientChain, bytes encodedMessage);

    error UnsupportedSourceChain(uint256 chainId);
    error InvalidCommitment();
    error InvalidEmitter();

    constructor(address manager) Transceiver(manager) { }

    /// @notice Initializes a new BoundlessTransceiver.
    /// @param verifier_ The address of the Risc0 verifier deployment on this chain (ideally Risc0VerifierRouter)
    function initialize(address verifier_) external initializer {
        super._initialize();
        verifier = IRiscZeroVerifier(verifier_);
    }

    function getTransceiverType() external view virtual override returns (string memory) {
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
    )
        internal
        override
    {
        (, bytes memory encodedTransceiverPayload) = TransceiverStructs.buildAndEncodeTransceiverMessage(
            BOUNDLESS_TRANSCEIVER_PAYLOAD_PREFIX,
            toWormholeFormat(caller),
            recipientNttManagerAddress,
            nttManagerMessage,
            abi.encodePacked(ManagerBase(nttManager).chainId())
        );

        // This is the event that the relayer is listening for and will build a ZK
        // proof of its inclusion in the source chain on the destination chain
        emit SendTransceiverMessage(recipientChain, encodedTransceiverPayload);
    }

    function _quoteDeliveryPrice(
        uint16, // targetChain,
        TransceiverStructs.TransceiverInstruction memory // transceiverInstruction
    )
        internal
        pure
        override
        returns (uint256)
    {
        return 0; // Relayer fees are not processed at this time
    }

    /// @notice Process a message along with its ZK proof of inclusion in the origin chain
    /// @param journalData The journal data that the proof commits to
    /// @param seal The opaque ZK proof seal that allows it to be verified on-chain
    /// @dev This function verifies the ZK proof, checks the commitments, then forwards the message to the NTT Manager.
    function receiveMessage(bytes calldata journalData, bytes calldata seal) external {
        Journal memory journal = abi.decode(journalData, (Journal));

        // parse the encoded Transceiver payload
        TransceiverStructs.TransceiverMessage memory parsedTransceiverMessage;
        TransceiverStructs.NttManagerMessage memory parsedNttManagerMessage;
        (parsedTransceiverMessage, parsedNttManagerMessage) = TransceiverStructs.parseTransceiverAndNttManagerMessage(
            BOUNDLESS_TRANSCEIVER_PAYLOAD_PREFIX, journal.encodedMessage
        );
        uint16 sourceChainId = toUint16(parsedTransceiverMessage.transceiverPayload);

        // Validate the source chain against authorized sources and the journal
        AuthorizedSource storage source = authorizedSources[sourceChainId];
        if (source.commitmentValidator == address(0)) {
            revert UnsupportedSourceChain(sourceChainId);
        }
        require(source.transceiverContract == journal.emitterContract, "Invalid emitter contract");
        // validate steel commitment against a trusted beacon block root from the commitment validator for the source
        // chain
        if (!ICommitmentValidator(source.commitmentValidator).validateCommitment(journal.commitment, TWO_OF_TWO_FLAG)) {
            revert InvalidCommitment();
        }

        // Verify the ZK proof
        bytes32 journalHash = sha256(journalData);
        verifier.verify(seal, source.imageID, journalHash);

        // If all prior checks have passed we can trust the ZK proof of an event emitted on the source chain
        // was included and then finalized by the chain. It can be passed to the NTT Manager.
        _deliverToNttManager(
            sourceChainId,
            parsedTransceiverMessage.sourceNttManagerAddress,
            toWormholeFormat(nttManager),
            parsedNttManagerMessage
        );
    }

    /// @notice Sets the commitment validator and source chain transceiverContract for a given Wormhole chain ID
    /// @param chainId The Wormhole chain ID
    /// @param validator The commitment validator contract to use for that chain
    /// @dev Only callable by the contract owner
    function setAuthorizedSource(
        uint16 chainId,
        bytes32 transceiverContract,
        address validator,
        bytes32 imageID
    )
        external
        onlyOwner
    {
        authorizedSources[chainId] = AuthorizedSource({
            transceiverContract: transceiverContract,
            commitmentValidator: validator,
            imageID: imageID
        });
    }

    function toUint16(bytes memory b) internal pure returns (uint16) {
        require(b.length >= 2, "Too short");
        uint16 x;
        assembly {
            x := shr(240, mload(add(b, 32)))
        }
        return x;
    }
}
