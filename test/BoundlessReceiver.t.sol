// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import { IRiscZeroVerifier, Receipt as RiscZeroReceipt } from "@risc0/contracts/IRiscZeroVerifier.sol";
import { RiscZeroMockVerifier } from "@risc0/contracts/test/RiscZeroMockVerifier.sol";
import { ConsensusState, Checkpoint } from "../src/tseth.sol";
import { BoundlessReceiver } from "../src/BoundlessReceiver.sol";
import { WormholeMock } from "./mocks/WormholeMock.sol";
import { Beacon } from "../src/lib/Beacon.sol";

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

contract RiscZeroTransceiverTest is Test {
    uint64 constant SLOTS_PER_EPOCH = 32;
    bytes4 constant MOCK_SELECTOR = bytes4(0);
    BoundlessReceiver br;
    RiscZeroMockVerifier verifier;
    ConsensusState root;
    bytes32 imageID;
    uint24 permissibleTimespan;
    address admin;
    address user;
    BoundlessReceiver.Journal journal;
    WormholeMock wormhole;
    address beaconEmitter;
    uint16 emitterChainId;

    function setUp() public {
        string memory proofData = vm.readFile("./test/proof.json");

        journal = abi.decode(vm.parseJsonBytes(proofData, ".journal"), (BoundlessReceiver.Journal));
        root = journal.preState;
        imageID = vm.parseJsonBytes32(proofData, ".image_id");
        permissibleTimespan = 3600 * 24 * 3; // 72 hr timespan
        admin = address(0xA11CE);
        user = address(0xB0B);

        wormhole = new WormholeMock();
        beaconEmitter = address(0x5678);
        emitterChainId = 1;

        verifier = new RiscZeroMockVerifier(MOCK_SELECTOR);
        br = new BoundlessReceiver(
            root,
            permissibleTimespan,
            address(verifier),
            imageID,
            address(wormhole),
            beaconEmitter,
            emitterChainId,
            admin,
            admin,
            Beacon.ETHEREUM_MAINNET_BEACON_CONFIG()
        );
    }

    function test_UserHasNoAdminRole() public view {
        assertFalse(br.hasRole(br.ADMIN_ROLE(), user));
    }

    function test_AdminHasAdminRole() public view {
        assertTrue(br.hasRole(br.ADMIN_ROLE(), admin));
    }

    function test_AdminHasDefaultAdminRole() public view {
        assertTrue(br.hasRole(br.DEFAULT_ADMIN_ROLE(), admin));
    }

    function testFuzz_AdminCanUpdatePermissibleTimespan(uint24 newPermissibleTimespan) public {
        vm.prank(admin);
        if (newPermissibleTimespan == permissibleTimespan) {
            vm.expectRevert(BoundlessReceiver.InvalidArgument.selector);
        }
        br.updatePermissibleTimespan(newPermissibleTimespan);

        if (newPermissibleTimespan != permissibleTimespan) {
            vm.assertEq(br.permissibleTimespan(), newPermissibleTimespan);
        }
    }

    function testFuzz_AdminCanUpdateImageID(bytes32 newImageID) public {
        vm.prank(admin);
        if (newImageID == imageID) {
            vm.expectRevert(BoundlessReceiver.InvalidArgument.selector);
        }
        br.updateImageID(newImageID);

        if (newImageID != imageID) {
            vm.assertEq(br.imageID(), newImageID);
        }
    }

    function test_ManualTransitionByAdmin() public {
        BoundlessReceiver.Journal memory journal = BoundlessReceiver.Journal({
            preState: root,
            postState: ConsensusState({
                currentJustifiedCheckpoint: Checkpoint({ epoch: 1, root: bytes32(uint256(1)) }),
                finalizedCheckpoint: Checkpoint({ epoch: 1, root: bytes32(uint256(1)) })
            }),
            finalizedSlot: SLOTS_PER_EPOCH
        });

        bytes memory journalData = abi.encode(journal);

        vm.expectEmit(true, true, true, true);
        emit BoundlessReceiver.Transitioned(
            journal.preState.finalizedCheckpoint.epoch,
            journal.postState.finalizedCheckpoint.epoch,
            journal.preState,
            journal.postState
        );

        vm.prank(admin);
        br.manualTransition(journalData);

        // TODO: Check if there's a cold-start with initialized value for internal root lookup
        (bytes32 root, bool valid) = br.blockRoot(journal.finalizedSlot, 0x1);
        assertEq(root, journal.postState.finalizedCheckpoint.root);
        assertTrue(valid, "Block root not valid when it should be by Boundless");

        (, bool validHigherLevel) = br.blockRoot(journal.finalizedSlot, 0x2);

        assertFalse(validHigherLevel, "Block root should not be valid by wormhole");
    }

    function test_ManualTransitionByNonAdminReverts() public {
        BoundlessReceiver.Journal memory journal = BoundlessReceiver.Journal({
            preState: root,
            postState: ConsensusState({
                currentJustifiedCheckpoint: Checkpoint({ epoch: 1, root: bytes32(uint256(1)) }),
                finalizedCheckpoint: Checkpoint({ epoch: 1, root: bytes32(uint256(1)) })
            }),
            finalizedSlot: SLOTS_PER_EPOCH
        });

        bytes memory journalData = abi.encode(journal);

        vm.prank(user);
        vm.expectRevert();
        br.manualTransition(journalData);
    }

    function test_ManualTransitionIgnoresPreState() public {
        BoundlessReceiver.Journal memory journal = BoundlessReceiver.Journal({
            preState: ConsensusState({
                currentJustifiedCheckpoint: Checkpoint({ epoch: 1, root: bytes32(uint256(1)) }),
                finalizedCheckpoint: Checkpoint({ epoch: 1, root: bytes32(uint256(1)) })
            }),
            postState: ConsensusState({
                currentJustifiedCheckpoint: Checkpoint({ epoch: 2, root: bytes32(uint256(2)) }),
                finalizedCheckpoint: Checkpoint({ epoch: 2, root: bytes32(uint256(2)) })
            }),
            finalizedSlot: 2 * SLOTS_PER_EPOCH
        });

        bytes memory journalData = abi.encode(journal);

        vm.expectEmit(true, true, true, true);
        emit BoundlessReceiver.Transitioned(
            journal.preState.finalizedCheckpoint.epoch,
            journal.postState.finalizedCheckpoint.epoch,
            journal.preState,
            journal.postState
        );

        vm.prank(admin);
        br.manualTransition(journalData);
        (bytes32 root, bool valid) = br.blockRoot(journal.finalizedSlot, 0x1);
        assertEq(root, journal.postState.finalizedCheckpoint.root);
        assertTrue(valid);
    }

    function test_ManualTransitionPermissibleTimespanLapsedSucceeds() public {
        BoundlessReceiver.Journal memory journal = BoundlessReceiver.Journal({
            preState: root,
            postState: ConsensusState({
                currentJustifiedCheckpoint: Checkpoint({
                    epoch: root.currentJustifiedCheckpoint.epoch + permissibleTimespan + 1,
                    root: bytes32(uint256(1))
                }),
                finalizedCheckpoint: Checkpoint({
                    epoch: root.finalizedCheckpoint.epoch + permissibleTimespan + 1,
                    root: bytes32(uint256(1))
                })
            }),
            finalizedSlot: (root.finalizedCheckpoint.epoch + permissibleTimespan + 1) * SLOTS_PER_EPOCH
        });

        bytes memory journalData = abi.encode(journal);

        vm.expectEmit(true, true, true, true);
        emit BoundlessReceiver.Transitioned(
            journal.preState.finalizedCheckpoint.epoch,
            journal.postState.finalizedCheckpoint.epoch,
            journal.preState,
            journal.postState
        );

        vm.prank(admin);
        br.manualTransition(journalData);
        (bytes32 root, bool valid) = br.blockRoot(journal.finalizedSlot, 0x1);
        assertEq(root, journal.postState.finalizedCheckpoint.root);
        assertTrue(valid);
    }

    function test_TransitionSucceeds() public {
        RiscZeroReceipt memory receipt = verifier.mockProve(imageID, sha256(abi.encode(journal)));

        vm.warp(
            Beacon.epochTimestamp(journal.preState.finalizedCheckpoint.epoch, Beacon.ETHEREUM_MAINNET_BEACON_CONFIG())
                + permissibleTimespan
        );
        vm.startPrank(admin);
        br.transition(abi.encode(journal), receipt.seal);
        vm.stopPrank();

        (bytes32 root, bool valid) = br.blockRoot(journal.finalizedSlot, 0x1);
        assertEq(root, journal.postState.finalizedCheckpoint.root);
        assertTrue(valid);
    }

    function test_TransitionFailsOnWrongPreState() public {
        BoundlessReceiver.Journal memory journal_ = BoundlessReceiver.Journal({
            preState: ConsensusState({
                currentJustifiedCheckpoint: Checkpoint({ epoch: 1, root: bytes32(uint256(1)) }),
                finalizedCheckpoint: Checkpoint({ epoch: 1, root: bytes32(uint256(1)) })
            }),
            postState: journal.postState,
            finalizedSlot: SLOTS_PER_EPOCH
        });
        RiscZeroReceipt memory receipt = verifier.mockProve(imageID, sha256(abi.encode(journal_)));

        vm.expectRevert(BoundlessReceiver.InvalidPreState.selector);
        vm.startPrank(admin);
        br.transition(abi.encode(journal_), receipt.seal);
        vm.stopPrank();
    }

    function test_TransitionFailsOnImpermissibleSpan() public {
        BoundlessReceiver.Journal memory journal_ = BoundlessReceiver.Journal({
            preState: root,
            postState: ConsensusState({
                currentJustifiedCheckpoint: Checkpoint({
                    epoch: root.currentJustifiedCheckpoint.epoch + permissibleTimespan + 1,
                    root: bytes32(uint256(1))
                }),
                finalizedCheckpoint: Checkpoint({
                    epoch: root.finalizedCheckpoint.epoch + permissibleTimespan + 1,
                    root: bytes32(uint256(1))
                })
            }),
            finalizedSlot: SLOTS_PER_EPOCH
        });
        RiscZeroReceipt memory receipt = verifier.mockProve(imageID, sha256(abi.encode(journal_)));

        vm.warp(
            Beacon.epochTimestamp(journal_.preState.finalizedCheckpoint.epoch, Beacon.ETHEREUM_MAINNET_BEACON_CONFIG())
                + permissibleTimespan + 1
        );

        vm.expectRevert(BoundlessReceiver.PermissibleTimespanLapsed.selector);
        vm.startPrank(admin);
        br.transition(abi.encode(journal_), receipt.seal);
        vm.stopPrank();
    }

    function test_WormholeMessageSuccess() public {
        uint64 epoch = 1;
        bytes32 root = bytes32(uint256(1));

        // Create mock wormhole message
        bytes memory encodedVM = abi.encode("mock_wormhole_message", epoch, root);
        wormhole.setMockVM(encodedVM, epoch, root, beaconEmitter, emitterChainId);

        vm.expectEmit(true, true, true, true);
        emit BoundlessReceiver.Confirmed(epoch, root, 2); // WORMHOLE_FLAG = 0x2

        br.receiveWormholeMessage(encodedVM);

        // Verify the root is confirmed with wormhole flag
        (bytes32 storedRoot, bool valid) = br.blockRoot(epoch, 2);
        assertEq(storedRoot, root);
        assertTrue(valid);
    }

    function test_WormholeMessageWrongEmitterAddress() public {
        uint64 epoch = 1;
        bytes32 root = bytes32(uint256(1));
        address wrongEmitter = address(0x9999);

        bytes memory encodedVM = abi.encodePacked("wrong_emitter", epoch, root);
        wormhole.setMockVM(encodedVM, epoch, root, wrongEmitter, emitterChainId);

        vm.expectRevert(BoundlessReceiver.UnauthorizedEmitterAddress.selector);
        br.receiveWormholeMessage(encodedVM);
    }

    function test_WormholeMessageWrongChainId() public {
        uint64 epoch = 1;
        bytes32 root = bytes32(uint256(1));
        uint16 wrongChainId = 999;

        bytes memory encodedVM = abi.encodePacked("wrong_chain", epoch, root);
        wormhole.setMockVM(encodedVM, epoch, root, beaconEmitter, wrongChainId);

        vm.expectRevert(BoundlessReceiver.UnauthorizedEmitterChainId.selector);
        br.receiveWormholeMessage(encodedVM);
    }

    function test_WormholeMessageInvalidVM() public {
        bytes memory invalidVM = abi.encodePacked("invalid_message");

        vm.expectRevert("Invalid VM");
        br.receiveWormholeMessage(invalidVM);
    }

    function test_Integration_WormholeThenBoundless_SameEpochRoot() public {
        uint64 epoch = root.finalizedCheckpoint.epoch + 1;
        uint64 slot = journal.finalizedSlot;
        bytes32 root_ = bytes32(uint256(1));

        console2.log(beaconEmitter);
        // Step 1: Wormhole attestation first
        bytes memory encodedVM = abi.encodePacked("wormhole_first", slot, root_);
        wormhole.setMockVM(encodedVM, journal.finalizedSlot, root_, beaconEmitter, emitterChainId);

        vm.expectEmit(true, true, true, true);
        emit BoundlessReceiver.Confirmed(slot, root_, 2); // WORMHOLE_FLAG = 0x2

        br.receiveWormholeMessage(encodedVM);

        // Verify wormhole-only confirmation (level 2)
        (bytes32 storedRoot, bool valid) = br.blockRoot(slot, 2);
        assertEq(storedRoot, root_);
        assertTrue(valid);

        // Step 2: Boundless transition for same epoch and root
        BoundlessReceiver.Journal memory journal = BoundlessReceiver.Journal({
            preState: root,
            postState: ConsensusState({
                currentJustifiedCheckpoint: Checkpoint({ epoch: epoch, root: root_ }),
                finalizedCheckpoint: Checkpoint({ epoch: epoch, root: root_ })
            }),
            finalizedSlot: slot
        });

        RiscZeroReceipt memory receipt = verifier.mockProve(imageID, sha256(abi.encode(journal)));

        vm.warp(
            Beacon.epochTimestamp(journal.preState.finalizedCheckpoint.epoch, Beacon.ETHEREUM_MAINNET_BEACON_CONFIG())
                + permissibleTimespan
        );

        vm.expectEmit(true, true, true, true);
        emit BoundlessReceiver.Transitioned(
            journal.preState.finalizedCheckpoint.epoch,
            journal.postState.finalizedCheckpoint.epoch,
            journal.preState,
            journal.postState
        );

        vm.expectEmit(true, true, true, true);
        emit BoundlessReceiver.Confirmed(slot, root_, 3); // BOUNDLESS_FLAG | WORMHOLE_FLAG = 0x3

        vm.prank(admin);
        br.transition(abi.encode(journal), receipt.seal);

        // Verify combined confirmation level (3 = 0x1 | 0x2)
        (bytes32 finalRoot, bool finalValid) = br.blockRoot(slot, 3);
        assertEq(finalRoot, root_);
        assertTrue(finalValid);
    }

    function test_Integration_BoundlessThenWormhole_SameEpochRoot() public {
        uint64 slot = journal.finalizedSlot;
        uint64 epoch = journal.postState.finalizedCheckpoint.epoch;
        bytes32 root_ = bytes32(uint256(2));

        // Step 1: Boundless transition first
        BoundlessReceiver.Journal memory journal = BoundlessReceiver.Journal({
            preState: root,
            postState: ConsensusState({
                currentJustifiedCheckpoint: Checkpoint({ epoch: epoch, root: root_ }),
                finalizedCheckpoint: Checkpoint({ epoch: epoch, root: root_ })
            }),
            finalizedSlot: slot
        });

        RiscZeroReceipt memory receipt = verifier.mockProve(imageID, sha256(abi.encode(journal)));

        vm.warp(
            Beacon.epochTimestamp(journal.preState.finalizedCheckpoint.epoch, Beacon.ETHEREUM_MAINNET_BEACON_CONFIG())
                + permissibleTimespan
        );

        vm.expectEmit(true, true, true, true);
        emit BoundlessReceiver.Transitioned(
            journal.preState.finalizedCheckpoint.epoch,
            journal.postState.finalizedCheckpoint.epoch,
            journal.preState,
            journal.postState
        );

        vm.expectEmit(true, true, true, true);
        emit BoundlessReceiver.Confirmed(slot, root_, 1); // BOUNDLESS_FLAG = 0x1
        vm.prank(admin);
        br.transition(abi.encode(journal), receipt.seal);

        // Verify boundless-only confirmation (level 1)
        (bytes32 storedRoot, bool valid) = br.blockRoot(slot, 1);
        assertEq(storedRoot, root_);
        assertTrue(valid);

        // Step 2: Wormhole attestation for same epoch and root
        bytes memory encodedVM = abi.encodePacked("wormhole_second", slot, root_);
        wormhole.setMockVM(encodedVM, slot, root_, beaconEmitter, emitterChainId);

        vm.expectEmit(true, true, true, true);
        emit BoundlessReceiver.Confirmed(slot, root_, 3); // BOUNDLESS_FLAG | WORMHOLE_FLAG = 0x3

        br.receiveWormholeMessage(encodedVM);

        // Verify combined confirmation level (3 = 0x1 | 0x2)
        (bytes32 finalRoot, bool finalValid) = br.blockRoot(slot, 3);
        assertEq(finalRoot, root_);
        assertTrue(finalValid);

        // Verify a lower confirmation level is enough as well
        (bytes32 finalRoot2, bool finalValid2) = br.blockRoot(slot, 2);
        assertEq(finalRoot2, root_);
        assertTrue(finalValid2);
    }

    function test_Integration_DifferentEpochs_SameRoot() public {
        bytes32 sameRoot = bytes32(uint256(0x1234));
        uint64 wormholeSlot = (root.finalizedCheckpoint.epoch + 1) * SLOTS_PER_EPOCH;
        uint64 boundlessSlot = (root.finalizedCheckpoint.epoch + 2) * SLOTS_PER_EPOCH;

        // Step 1: Wormhole attestation for epoch root.epoch + 1
        bytes memory encodedVM = abi.encodePacked("wormhole_epoch3", wormholeSlot, sameRoot);
        wormhole.setMockVM(encodedVM, wormholeSlot, sameRoot, beaconEmitter, emitterChainId);

        br.receiveWormholeMessage(encodedVM);

        // Step 2: Boundless transition for epoch root.epoch + 2  with same root
        BoundlessReceiver.Journal memory journal = BoundlessReceiver.Journal({
            preState: root,
            postState: ConsensusState({
                currentJustifiedCheckpoint: Checkpoint({ epoch: boundlessSlot, root: sameRoot }),
                finalizedCheckpoint: Checkpoint({ epoch: boundlessSlot, root: sameRoot })
            }),
            finalizedSlot: boundlessSlot
        });

        RiscZeroReceipt memory receipt = verifier.mockProve(imageID, sha256(abi.encode(journal)));

        vm.warp(
            Beacon.epochTimestamp(journal.preState.finalizedCheckpoint.epoch, Beacon.ETHEREUM_MAINNET_BEACON_CONFIG())
                + permissibleTimespan
        );

        vm.prank(admin);
        br.transition(abi.encode(journal), receipt.seal);

        // Verify wormhole-only confirms epoch root.epoch + 1 with level 2
        (bytes32 wormholeRoot, bool wormholeValid) = br.blockRoot(wormholeSlot, 2);
        assertEq(wormholeRoot, sameRoot);
        assertTrue(wormholeValid);

        // Verify boundless-only confirms epoch root.epoch + 2 with level 1
        (bytes32 boundlessRoot, bool boundlessValid) = br.blockRoot(boundlessSlot, 1);
        assertEq(boundlessRoot, sameRoot);
        assertTrue(boundlessValid);

        // Verify no cross-contamination
        (, bool invalidValid) = br.blockRoot(wormholeSlot, 1);
        assertFalse(invalidValid);

        (, bool invalidValid2) = br.blockRoot(boundlessSlot, 2);
        assertFalse(invalidValid2);
    }
}
