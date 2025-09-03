// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.8 <0.9.0;

import { BoundlessTransceiver, BOUNDLESS_TRANSCEIVER_PAYLOAD_PREFIX } from "../src/BoundlessTransceiver.sol";
import { TransceiverStructs } from "wormhole-ntt/libraries/TransceiverStructs.sol";
import { packTrimmedAmount, TrimmedAmount } from "wormhole-ntt/libraries/TransceiverStructs.sol";
import { NttManager } from "wormhole-ntt/NttManager/NttManager.sol";
import { INttManager } from "wormhole-ntt/interfaces/INttManager.sol";
import { IManagerBase } from "wormhole-ntt/interfaces/IManagerBase.sol";
import { ERC1967Proxy } from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Receipt as RiscZeroReceipt } from "@risc0/contracts/IRiscZeroVerifier.sol";
import { RiscZeroMockVerifier } from "@risc0/contracts/test/RiscZeroMockVerifier.sol";
import { Steel, Encoding } from "@risc0/contracts/steel/Steel.sol";
import { toWormholeFormat } from "wormhole-solidity-sdk/Utils.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { DummyTokenMintAndBurn } from "./mocks/DummyToken.sol";
import { DummyReceiver } from "./mocks/DummyReceiver.sol";

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";

contract BoundlessTransceiverTest is Test {
    address constant OWNER = address(1004);

    uint64 constant RATE_LIMIT_DURATION = 0;
    bool constant SKIP_RATE_LIMITING = true;
    bytes4 constant MOCK_SELECTOR = bytes4(0); // R0 proof selector for testing
    uint16 constant CHAIN_ID_A = 333;
    uint16 constant CHAIN_ID_B = 666;
    uint16 constant CHAIN_ID_C = 999;
    bytes32 public constant NTT_MESSAGE_INCLUSION_ID = // Note this will change with every build. Ok as a mock only
     bytes32(0x1f0dac03fa82751534fe6372619fd6e9975c169864e48ece108fca6c4366df3d);

    NttManager manager;
    DummyTokenMintAndBurn token;
    RiscZeroMockVerifier verifier;
    DummyReceiver receiver;
    BoundlessTransceiver transceiver;

    function setUp() public {
        vm.startPrank(OWNER);
        token = new DummyTokenMintAndBurn();

        address managerImplementation = address(
            new NttManager(
                address(token), IManagerBase.Mode.LOCKING, CHAIN_ID_A, RATE_LIMIT_DURATION, SKIP_RATE_LIMITING
            )
        );

        verifier = new RiscZeroMockVerifier(MOCK_SELECTOR);
        receiver = new DummyReceiver();

        manager = NttManager(address(new ERC1967Proxy(managerImplementation, "")));
        manager.initialize();
        BoundlessTransceiver implementation = new BoundlessTransceiver(address(manager));

        bytes memory initializer =
            abi.encodeCall(BoundlessTransceiver.initialize, (address(verifier), NTT_MESSAGE_INCLUSION_ID));
        transceiver = BoundlessTransceiver(address(new ERC1967Proxy(address(implementation), initializer)));
        transceiver.setAuthorizedSource(CHAIN_ID_B, bytes32(0), receiver);
        manager.setTransceiver(address(transceiver));
        vm.stopPrank();
    }

    // Testing sending a message from CHAIN_A
    function test_sendMessage() public {
        uint16 recipientChainId = 10;
        bytes32 recipientNttManagerAddress = bytes32(uint256(1010));
        bytes memory nttManagerMessage = bytes("nttManagerMessage");
        bytes32 refundAddress = bytes32(uint256(1011));
        TransceiverStructs.TransceiverInstruction memory instruction =
            TransceiverStructs.TransceiverInstruction(0, bytes(""));

        (, bytes memory encodedTransceiverPayload) = TransceiverStructs.buildAndEncodeTransceiverMessage(
            BOUNDLESS_TRANSCEIVER_PAYLOAD_PREFIX,
            toWormholeFormat(address(manager)),
            recipientNttManagerAddress,
            nttManagerMessage,
            abi.encodePacked(CHAIN_ID_A)
        );

        vm.prank(address(manager));
        vm.chainId(1); // Ethereum mainnet

        vm.expectEmit(address(transceiver));
        // emit the event we expect to see
        emit BoundlessTransceiver.SendTransceiverMessage(recipientChainId, encodedTransceiverPayload);
        transceiver.sendMessage(
            recipientChainId, instruction, nttManagerMessage, recipientNttManagerAddress, refundAddress
        );
    }

    function test_sendMessageNotManager() public {
        uint16 recipientChainId = 10;
        bytes32 recipientNttManagerAddress = bytes32(uint256(1010));
        bytes memory nttManagerMessage = bytes("nttManagerMessage");
        bytes32 refundAddress = bytes32(uint256(1011));
        TransceiverStructs.TransceiverInstruction memory instruction =
            TransceiverStructs.TransceiverInstruction(0, bytes(""));

        vm.chainId(1); // Ethereum mainnet
        vm.prank(address(OWNER));
        vm.expectRevert(abi.encodeWithSignature("CallerNotNttManager(address)", OWNER));
        transceiver.sendMessage(
            recipientChainId, instruction, nttManagerMessage, recipientNttManagerAddress, refundAddress
        );
    }

    function test_receiveMessageUnsupportedChain() public {
        uint240 consensusSlot = 1_234_567_890;
        bytes32 blockRoot = bytes32(uint256(1022));

        bytes32 messageId = bytes32(uint256(25));
        bytes32 recipientNttManagerAddress = bytes32(uint256(uint160(address(manager))));

        address to = address(1234);
        uint64 amount = 12_345_670_000_000_000;

        bytes memory encodedTransceiverMessage;
        bytes32 nttManagerMessageHash;
        {
            TransceiverStructs.NativeTokenTransfer memory ntt = TransceiverStructs.NativeTokenTransfer({
                amount: packTrimmedAmount(amount, 18),
                sourceToken: bytes32(uint256(1022)),
                to: bytes32(uint256(uint160(to))), // convert to wormhole format
                toChain: CHAIN_ID_A,
                additionalPayload: new bytes(0)
            });
            bytes memory encodedNtt = TransceiverStructs.encodeNativeTokenTransfer(ntt);

            TransceiverStructs.NttManagerMessage memory nttManagerMessage = TransceiverStructs.NttManagerMessage({
                id: messageId,
                sender: bytes32(uint256(1)),
                payload: encodedNtt
            });
            bytes memory encodedNttManagerMessage = TransceiverStructs.encodeNttManagerMessage(nttManagerMessage);
            nttManagerMessageHash = TransceiverStructs.nttManagerMessageDigest(2, nttManagerMessage);

            TransceiverStructs.TransceiverMessage memory transceiverMessage = TransceiverStructs.TransceiverMessage({
                sourceNttManagerAddress: bytes32(0),
                recipientNttManagerAddress: recipientNttManagerAddress,
                nttManagerPayload: encodedNttManagerMessage,
                transceiverPayload: abi.encodePacked(CHAIN_ID_C)
            });
            encodedTransceiverMessage =
                TransceiverStructs.encodeTransceiverMessage(BOUNDLESS_TRANSCEIVER_PAYLOAD_PREFIX, transceiverMessage);
        }

        bytes memory journalBytes = abi.encode(
            BoundlessTransceiver.Journal({
                commitment: Steel.Commitment(Encoding.encodeVersionedID(consensusSlot, 2), blockRoot, bytes32(0x0)),
                encodedMessage: encodedTransceiverMessage,
                emitterContract: bytes32(0)
            })
        );

        vm.expectRevert(abi.encodeWithSelector(BoundlessTransceiver.UnsupportedSourceChain.selector, CHAIN_ID_C));
        transceiver.receiveMessage(journalBytes, bytes("dummy seal"));
    }

    function test_receiveMessage() public {
        uint240 consensusSlot = 1_234_567_890;
        bytes32 blockRoot = bytes32(uint256(1022));

        bytes32 messageId = bytes32(uint256(25));
        bytes32 recipientNttManagerAddress = bytes32(uint256(uint160(address(manager))));

        address to = address(1234);
        uint64 amount = 12_345_670_000_000_000;

        bytes memory encodedTransceiverMessage;
        bytes32 nttManagerMessageHash;
        {
            TransceiverStructs.NativeTokenTransfer memory ntt = TransceiverStructs.NativeTokenTransfer({
                amount: packTrimmedAmount(amount, 18),
                sourceToken: bytes32(uint256(1022)),
                to: bytes32(uint256(uint160(to))), // convert to wormhole format
                toChain: CHAIN_ID_A,
                additionalPayload: new bytes(0)
            });
            bytes memory encodedNtt = TransceiverStructs.encodeNativeTokenTransfer(ntt);

            TransceiverStructs.NttManagerMessage memory nttManagerMessage = TransceiverStructs.NttManagerMessage({
                id: messageId,
                sender: bytes32(uint256(1)),
                payload: encodedNtt
            });
            bytes memory encodedNttManagerMessage = TransceiverStructs.encodeNttManagerMessage(nttManagerMessage);
            nttManagerMessageHash = TransceiverStructs.nttManagerMessageDigest(CHAIN_ID_B, nttManagerMessage);

            TransceiverStructs.TransceiverMessage memory transceiverMessage = TransceiverStructs.TransceiverMessage({
                sourceNttManagerAddress: bytes32(0),
                recipientNttManagerAddress: recipientNttManagerAddress,
                nttManagerPayload: encodedNttManagerMessage,
                transceiverPayload: abi.encodePacked(CHAIN_ID_B)
            });
            encodedTransceiverMessage =
                TransceiverStructs.encodeTransceiverMessage(BOUNDLESS_TRANSCEIVER_PAYLOAD_PREFIX, transceiverMessage);
        }

        bytes memory journalBytes = abi.encode(
            BoundlessTransceiver.Journal({
                commitment: Steel.Commitment(Encoding.encodeVersionedID(consensusSlot, 2), blockRoot, bytes32(0x0)),
                encodedMessage: encodedTransceiverMessage,
                emitterContract: bytes32(0)
            })
        );

        token.mint(address(manager), amount);

        // create a mock proof
        RiscZeroReceipt memory receipt = verifier.mockProve(NTT_MESSAGE_INCLUSION_ID, sha256(journalBytes));

        vm.expectRevert(BoundlessTransceiver.InvalidCommitment.selector);
        transceiver.receiveMessage(journalBytes, receipt.seal);

        // Set the expected block root in the dummy receiver
        receiver.setBlockRoot(uint64(consensusSlot), blockRoot);

        transceiver.receiveMessage(journalBytes, receipt.seal);
        require(token.balanceOf(to) == amount, "Amount Incorrect");

        // ensure working replay protection
        token.mint(address(manager), amount);
        vm.expectRevert(abi.encodeWithSignature("TransceiverAlreadyAttestedToMessage(bytes32)", nttManagerMessageHash));
        transceiver.receiveMessage(journalBytes, receipt.seal);
    }
}
