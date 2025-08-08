// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import { Transceiver } from "wormhole-ntt/Transceiver/Transceiver.sol";
import { TransceiverStructs } from "wormhole-ntt/libraries/TransceiverStructs.sol";
import { toWormholeFormat } from "wormhole-solidity-sdk/Utils.sol";
import { BoundlessReceiver } from "./BoundlessReceiver.sol";
import { IRiscZeroVerifier } from "./interfaces/IRiscZeroVerifier.sol";
import { Steel } from "@risc0/contracts/steel/Steel.sol";

contract BoundlessTransceiver is Transceiver {

    /// @notice The Risc0 verifier contract used to verify the ZK proof.
    IRiscZeroVerifier public immutable verifier;

    /// @notice The BoundlessReceiver contract that will be used to verify the block roots.
    BoundlessReceiver public immutable boundlessReceiver;

    /// @notice The image ID of the Risc0 program used for event inclusion proofs.
    bytes32 public immutable imageID;

    uint16 sourceChainId = 2; // Currently can only receive from Ethereum mainnet

    /// @notice Journal that is committed to by the guest.
    struct Journal {
        // Commitment locks this proof to a specific block root
        // which can be verified against the BoundlessReceiver contract
        Steel.Commitment commitment;

        // Commits to the ntt manager message that was sent
        bytes32 nttManagerMessageDigest;
        // Commits to the NTT manager that emitted the message (wormhole encoded address)
        bytes32 emitterNttManager;
    }

    constructor(
        address _manager,
        address _r0Verifier,
        address _blockRootReceiver,
        bytes32 _imageID
    ) Transceiver(_manager) {
        verifier = IRiscZeroVerifier(_r0Verifier);
        boundlessReceiver = BoundlessReceiver(_blockRootReceiver);
        imageID = _imageID;
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
        uint256 deliveryPayment,
        address caller,
        bytes32 recipientNttManagerAddress,
        bytes32 refundAddress,
        TransceiverStructs.TransceiverInstruction memory transceiverInstruction,
        bytes memory nttManagerMessage
    ) internal override {
        revert("BoundlessTransceiver: Currently sending messages is not supported");
    }

    function _quoteDeliveryPrice(
        uint16 targetChain,
        TransceiverStructs.TransceiverInstruction memory transceiverInstruction
    ) internal view override returns (uint256) {
        return 0; // Placeholder for delivery price logic
    }

    /// Callable by anyone who is routing a message
    function receiveMessage(
        bytes calldata encodedMessage, bytes calldata journalData, bytes calldata seal
    ) external {
        TransceiverStructs.NttManagerMessage memory message = TransceiverStructs.parseNttManagerMessage(encodedMessage);
        Journal memory journal = abi.decode(journalData, (Journal));

        // Ensure the message digest matches the value committed to in the journal
        bytes32 recoveredDigest = TransceiverStructs.nttManagerMessageDigest(sourceChainId, message);
        require(recoveredDigest == journal.nttManagerMessageDigest, "Computed digest does not match the journal");

        // TOOD: Validate the steel commitment against a trusted block root in the BoundlessReceiver
        require(Steel.validateCommitment(journal.commitment), "Invalid commitment");

        // Verify the ZK proof
        bytes32 journalHash = sha256(journalData);
        verifier.verify(seal, imageID, journalHash);

        _deliverToNttManager(
            sourceChainId,
            journal.emitterNttManager,
            toWormholeFormat(nttManager),
            message
        );
    }

}
