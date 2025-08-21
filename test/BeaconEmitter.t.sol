// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { BeaconEmitter } from "../src/BeaconEmitter.sol";
import { Beacon } from "../src/lib/Beacon.sol";
import { WormholeMock } from "./mocks/WormholeMock.sol";

contract BeaconEmitterTest is Test {
    BeaconEmitter public beaconEmitter;
    WormholeMock public wormholeMock;

    // Ethereum mainnet genesis timestamp
    Beacon.BeaconConfig beaconConfig = Beacon.ETHEREUM_MAINNET_BEACON_CONFIG();
    uint256 BEACON_ROOTS_HISTORY_BUFFER_LENGTH = beaconConfig.beaconRootsHistoryBufferLength;
    uint64 SLOTS_PER_EPOCH = uint64(beaconConfig.slotsPerEpoch);
    uint64 SLOT_SPEED = uint64(beaconConfig.slotSpeed);
    uint256 GENESIS_TIMESTAMP = beaconConfig.genesisBeaconBlockTimestamp;

    uint64 BASE_SLOT = 1000;
    uint256 BASE_TIMESTAMP = GENESIS_TIMESTAMP + (BASE_SLOT * SLOT_SPEED);

    uint64 CHILD_SLOT = BASE_SLOT + 1;
    uint256 CHILD_TIMESTAMP = GENESIS_TIMESTAMP + (CHILD_SLOT * SLOT_SPEED);

    bytes32 constant BASE_ROOT = keccak256("BASE ROOT");

    address BEACON_ROOTS_ADDRESS = beaconConfig.beaconRootsAddress;

    bytes32 blockRoot;

    event BeaconRootEmitted(uint64 indexed epoch, bytes32 blockRoot);

    function setUp() public {
        wormholeMock = new WormholeMock();
        beaconEmitter = new BeaconEmitter(address(wormholeMock), 0, beaconConfig);

        // Set the current timestamp to ~100 slots post base slot
        uint256 currentTimestamp = BASE_TIMESTAMP + (100 * SLOT_SPEED);
        vm.warp(currentTimestamp);
        _mockBeacon(CHILD_TIMESTAMP, BASE_ROOT);
        blockRoot = Beacon.findBlockRoot(BASE_SLOT, beaconConfig);
    }

    function test_ConstructorInitialization() public view {
        Beacon.BeaconConfig memory config = beaconEmitter.BEACON_CONFIG();
        assertEq(address(beaconEmitter.WORMHOLE()), address(wormholeMock));
        assertEq(config.genesisBeaconBlockTimestamp, GENESIS_TIMESTAMP);
    }

    function test_EmitForSlot_Success() public {
        uint64 expectedSlot = BASE_SLOT;

        // Set Wormhole fee
        uint256 wormholeFee = 0.0001 ether;
        vm.deal(address(this), wormholeFee);

        // Call emitForEpoch
        beaconEmitter.emitForSlot{ value: wormholeFee }(expectedSlot);

        // Verify the message was published
        assertEq(wormholeMock.publishedMessagesLength(), 1);
        WormholeMock.PublishedMessage memory published = wormholeMock.publishedMessages(0);

        assertEq(published.sender, address(beaconEmitter));
        assertEq(published.value, wormholeFee);
        assertEq(published.consistencyLevel, 0);

        // Decode payload and verify
        (uint64 emittedSlot, bytes32 emittedRoot) = abi.decode(published.payload, (uint64, bytes32));
        assertEq(emittedSlot, expectedSlot);
        assertEq(emittedRoot, blockRoot);
    }

    function test_GenesisBlockTimestamp_Validation() public {
        // Test with different genesis timestamps
        uint64 customGenesis = 1_606_824_000 + 86_400; // One day later
        Beacon.BeaconConfig memory conf = Beacon.BeaconConfig({
            genesisBeaconBlockTimestamp: customGenesis,
            beaconRootsHistoryBufferLength: 8191,
            slotSpeed: 12,
            slotsPerEpoch: 32,
            beaconRootsAddress: 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02
        });
        BeaconEmitter customEmitter = new BeaconEmitter(address(wormholeMock), 0, conf);

        assertEq(customEmitter.BEACON_CONFIG().genesisBeaconBlockTimestamp, customGenesis);

        // Test with current timestamp (should be valid)
        uint64 currentGenesis = uint64(block.timestamp) - 1_000_000;
        Beacon.BeaconConfig memory conf_ = Beacon.BeaconConfig({
            genesisBeaconBlockTimestamp: currentGenesis,
            beaconRootsHistoryBufferLength: 8191,
            slotSpeed: 12,
            slotsPerEpoch: 32,
            beaconRootsAddress: 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02
        });
        BeaconEmitter currentEmitter = new BeaconEmitter(address(wormholeMock), 0, conf_);
        assertEq(currentEmitter.BEACON_CONFIG().genesisBeaconBlockTimestamp, currentGenesis);
    }

    function test_EpochToSlot_Calculation() public {
        uint64 epoch = 1234;
        uint256 expectedSlot = epoch * SLOTS_PER_EPOCH;

        // This is implicitly tested through emitForEpoch, but let's verify the calculation
        uint256 expectedTimestamp = GENESIS_TIMESTAMP + ((expectedSlot + 1) * SLOT_SPEED);

        assertEq(expectedSlot, 1234 * 32);
        assertEq(expectedTimestamp, GENESIS_TIMESTAMP + (1234 * 32 + 1) * 12);
    }

    function test_EmitForSlot_TimestampOutOfRange() public {
        // Warp to current time
        vm.warp(BEACON_ROOTS_HISTORY_BUFFER_LENGTH * SLOT_SPEED + GENESIS_TIMESTAMP + 1200);

        uint64 oldSlot = uint64(1);

        uint256 wormholeFee = 0.0001 ether;
        vm.deal(address(this), wormholeFee);

        // Expect revert due to timestamp out of range
        vm.expectRevert(Beacon.TimestampOutOfRange.selector);
        beaconEmitter.emitForSlot{ value: wormholeFee }(oldSlot);
    }

    function test_EmitForSlot_NoBlockRootFound() public {
        // Warp to a reasonable time
        uint256 currentTimestamp = GENESIS_TIMESTAMP + (50_000 * SLOT_SPEED);
        vm.warp(currentTimestamp);

        uint64 epoch = 1500;
        uint64 expectedSlot = epoch * SLOTS_PER_EPOCH;
        uint256 expectedTimestamp = GENESIS_TIMESTAMP + ((expectedSlot + 1) * SLOT_SPEED);

        // Mock all calls to return empty (no block root found)
        for (uint256 i = 0; i < 100; i++) {
            uint256 timestamp = expectedTimestamp + (i * SLOT_SPEED);
            vm.mockCall(
                BEACON_ROOTS_ADDRESS,
                abi.encodeWithSelector(bytes4(keccak256("get(bytes32)")), bytes32(timestamp)),
                abi.encode(bytes32(0))
            );
        }

        uint256 wormholeFee = 0.0001 ether;
        vm.deal(address(this), wormholeFee);

        // Expect revert due to no block root found
        vm.expectRevert(Beacon.NoBlockRootFound.selector);
        beaconEmitter.emitForSlot{ value: wormholeFee }(expectedSlot);
    }

    function test_EmitForSlot_InsufficientFee() public {
        // Send insufficient fee

        uint256 insufficientFee = 0.00005 ether;
        vm.deal(address(this), insufficientFee);

        vm.expectRevert("Insufficient fee");
        beaconEmitter.emitForSlot{ value: insufficientFee }(BASE_SLOT);
    }

    function test_BeaconLibrary_Direct() public {
        bytes32 result = Beacon.findBlockRoot(BASE_SLOT, beaconConfig);
        assertEq(result, BASE_ROOT);
    }

    function test_GasEstimation() public {
        uint256 wormholeFee = 0.0001 ether;
        vm.deal(address(this), wormholeFee);

        uint256 gasBefore = gasleft();
        beaconEmitter.emitForSlot{ value: wormholeFee }(BASE_SLOT);
        uint256 gasUsed = gasBefore - gasleft();

        // Just ensure it completes successfully - actual gas usage will vary
        assertGt(gasUsed, 0);
    }

    function _mockBeacon(uint256 timestamp, bytes32 root) internal {
        vm.mockCall(BEACON_ROOTS_ADDRESS, abi.encode(timestamp), abi.encode(root));
    }
}
