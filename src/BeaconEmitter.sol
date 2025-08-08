// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import { IWormhole } from "wormhole-solidity-sdk/interfaces/IWormhole.sol";
import { Beacon } from "./lib/Beacon.sol";

/// @title BeaconEmitter
/// @notice Contract for reading beacon block roots via EIP-4788 and emitting them as multicast Wormhole messages.
/// @dev This contract enables cross-chain communication of Ethereum beacon chain state by reading
/// block roots from the beacon chain and publishing them through Wormhole's messaging protocol.
/// @dev Requirements:
/// - Must be deployed on a chain that uses beacon chain consensus and supports EIP-4788 (e.g., Ethereum, Gnosis)
/// - Block roots can only be retrieved while within the beacon roots history buffer (8191 slots ~27 hours on Ethereum)
/// - Receivers must verify message origin (chain/contract) before processing
contract BeaconEmitter {
    /// @notice Wormhole consistency level for message finality.
    /// @dev Level 0 requires the block containing the message to be finalized.
    uint8 immutable CONSISTENCY_LEVEL = 0;

    /// @notice The Wormhole core contract instance for cross-chain messaging.
    /// @dev Immutable to prevent upgrade risks and ensure consistent message routing.
    IWormhole public immutable WORMHOLE;

    Beacon.BeaconConfig private _BEACON_CONFIG;

    /// @notice Creates a new BeaconEmitter contract instance.
    /// @dev Initializes the contract with Wormhole integration and genesis timestamp configuration.
    /// @param wormhole The address of the Wormhole core contract for cross-chain messaging.
    /// @param consistencyLevel The Wormhole consistency level for message finality.
    constructor(address wormhole, uint8 consistencyLevel, Beacon.BeaconConfig memory beaconConfig) {
        WORMHOLE = IWormhole(wormhole);
        CONSISTENCY_LEVEL = consistencyLevel;
        _BEACON_CONFIG = beaconConfig;
    }

    /// @notice Emits a Wormhole message containing the beacon block root for a specific slot.
    /// @dev Retrieves the beacon block root for the given slot using EIP-4788 and publishes
    /// it as a Wormhole message for cross-chain consumption.
    /// @param slot The beacon chain slot number to retrieve the block root for.
    function emitForSlot(uint64 slot) external payable {
        bytes32 blockRoot = Beacon.findBlockRoot(slot, _BEACON_CONFIG);

        WORMHOLE.publishMessage{ value: msg.value }(0, abi.encode(slot, blockRoot), CONSISTENCY_LEVEL);
    }

    function BEACON_CONFIG() external view returns (Beacon.BeaconConfig memory) {
        return _BEACON_CONFIG;
    }
}
