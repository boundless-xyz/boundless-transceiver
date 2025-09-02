// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import { AccessControl, Context } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Transceiver } from "wormhole-ntt/Transceiver/Transceiver.sol";
import { ManagerBase } from "wormhole-ntt/NttManager/ManagerBase.sol";
import { ContextUpgradeable } from "wormhole-ntt/libraries/external/ContextUpgradeable.sol";
import { TransceiverStructs } from "wormhole-ntt/libraries/TransceiverStructs.sol";
import { toWormholeFormat } from "wormhole-solidity-sdk/Utils.sol";
import { TWO_OF_TWO_FLAG } from "./BlockRootOracle.sol";
import { ICommitmentValidator } from "./interfaces/ICommitmentValidator.sol";
import { IRiscZeroVerifier } from "./interfaces/IRiscZeroVerifier.sol";
import { Steel, Encoding as SteelEncoding } from "@risc0/contracts/steel/Steel.sol";

/// @dev Prefix for all TransceiverMessage payloads bytes4(keccak256("BoundlessTransceiverPayload"))
bytes4 constant BOUNDLESS_TRANSCEIVER_PAYLOAD_PREFIX = 0x1d49a45d;

contract BoundlessTransceiver is AccessControl, Transceiver {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice The Risc0 verifier contract used to verify the ZK proof.
    IRiscZeroVerifier public immutable verifier;

    /// @notice Map from [Wormhole chain ID](https://wormhole.com/docs/products/reference/chain-ids/)
    /// @notice to contract that will be used to verify the Steel commitments from the foreign chain.
    mapping(uint16 => ICommitmentValidator) public commitmentValidators;

    /// @notice The image ID of the Risc0 program used for event inclusion proofs.
    bytes32 public immutable imageID;

    /// @notice Journal that is committed to by the guest.
    struct Journal {
        // Commitment locks this proof to a specific block root
        // which can be verified against the blockRootOracle contract
        Steel.Commitment commitment;
        // The encoded TransceiverMessage that this proof commits to
        bytes encodedMessage;
        // The contract that emitted the message event
        address emitterContract;
    }

    /// @notice Emitted when a message is sent from this transceiver.
    /// @param recipientChain The chain ID of the recipient.
    /// @param encodedMessage The encoded TransceiverMessage.
    event SendTransceiverMessage(uint16 indexed recipientChain, bytes encodedMessage);

    /// @notice Constructs a new BoundlessTransceiver.
    /// @param _manager The address of the NTT Manager contract
    /// @param _r0Verifier The address of the Risc0 verifier deployment on this chain (ideally Risc0VerifierRouter)
    /// @param _imageID The image ID of the Risc0 program used for event inclusion proofs
    constructor(
        address _manager,
        address _r0Verifier,
        bytes32 _imageID,
        address admin,
        address superAdmin
    )
        Transceiver(_manager)
    {
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(DEFAULT_ADMIN_ROLE, superAdmin);

        verifier = IRiscZeroVerifier(_r0Verifier);
        imageID = _imageID;
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

        // Ensure the message came from the expected contract
        // require(journal.emitterContract == ethereumBoundlessTransceiver, "Invalid emitter contract");

        // parse the encoded Transceiver payload
        TransceiverStructs.TransceiverMessage memory parsedTransceiverMessage;
        TransceiverStructs.NttManagerMessage memory parsedNttManagerMessage;
        (parsedTransceiverMessage, parsedNttManagerMessage) = TransceiverStructs.parseTransceiverAndNttManagerMessage(
            BOUNDLESS_TRANSCEIVER_PAYLOAD_PREFIX, journal.encodedMessage
        );
        uint16 sourceChainId = toUint16(parsedTransceiverMessage.transceiverPayload);

        // Validate the steel commitment against a trusted beacon block root from the commitment validator for the source chain
        ICommitmentValidator validator = commitmentValidators[sourceChainId];
        if (address(validator) == address(0)) {
            revert("Unsupported source chain");
        }
        require(commitmentValidators[sourceChainId].validateCommitment(journal.commitment, TWO_OF_TWO_FLAG), "Invalid commitment");

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

    /// @notice Sets the commitment validator for a given Wormhole chain ID
    /// @param chainId The Wormhole chain ID
    /// @param validator The commitment validator contract to use for that chain
    /// @dev Only callable by an account with the ADMIN_ROLE
    function setCommitmentValidator(uint16 chainId, ICommitmentValidator validator) external onlyRole(ADMIN_ROLE) {
        commitmentValidators[chainId] = validator;
    }

    function toUint16(bytes memory b) internal pure returns (uint16) {
        require(b.length >= 2, "Too short");
        uint16 x;
        assembly {
            x := shr(240, mload(add(b, 32)))
        }
        return x;
    }

    // Overrides needed to fix inheritance linearization with OpenZeppelin AccessControl and Transceiver
    function _msgSender() internal view override(Context, ContextUpgradeable) returns (address) {
        return super._msgSender();
    }

    function _msgData() internal view override(Context, ContextUpgradeable) returns (bytes calldata) {
        return super._msgData();
    }

    function _contextSuffixLength() internal view override(Context, ContextUpgradeable) returns (uint256) {
        return super._contextSuffixLength();
    }
}
