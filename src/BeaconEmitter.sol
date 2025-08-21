// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import { IWormhole } from "wormhole-sdk/interfaces/IWormhole.sol";
import { Beacon } from "./lib/Beacon.sol";

/**
 * @title BeaconEmitter
 * @notice Read beacon block roots via EIP-4788 and emit them as multicast Wormhole messages.
 *
 * @dev Note this must be deployed on a chain that uses beacon chain consensus and supports EIP-4788, such as Ethereum
 * or Gnosis
 * @dev The block root for a given slot can only be retrieved while it is in the beacon roots history buffer, which is
 * 8191 slots (about 27 hours) on Ethereum.
 * @dev A receiver must check that messages are from the correct chain/contract before processing them
 *
 */
contract BeaconEmitter {
    /// @notice Wormhole consistency level for message finality.
    /// @dev Level 0 requires the block containing the message to be finalized.
    uint8 immutable CONSISTENCY_LEVEL = 0;

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

    function emitForSlot(uint64 slot) external payable {
        bytes32 blockRoot = Beacon.findBlockRoot(slot, _BEACON_CONFIG);

        WORMHOLE.publishMessage{ value: msg.value }(0, abi.encode(slot, blockRoot), CONSISTENCY_LEVEL);
    }

    function BEACON_CONFIG() external view returns (Beacon.BeaconConfig memory) {
        return _BEACON_CONFIG;
    }
}
