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
    uint8 constant CONSISTENCY_LEVEL = 0; // Block containing message must be finalized

    IWormhole public immutable WORMHOLE;
    uint256 public immutable GENESIS_BLOCK_TIMESTAMP;

    /**
     * @notice Creates a new BeaconEmitter contract.
     * @param wormhole The address of the Wormhole core contract.
     * @param genesisBlockTimestamp The timestamp of the genesis beacon block of the chain this contract is deployed
     * on. 1606824000 for Ethereum mainnet.
     */
    constructor(address wormhole, uint256 genesisBlockTimestamp) {
        WORMHOLE = IWormhole(wormhole);
        GENESIS_BLOCK_TIMESTAMP = genesisBlockTimestamp;
    }

    function emitForSlot(uint64 slot) external payable {
        bytes32 blockRoot = Beacon.findBlockRoot(GENESIS_BLOCK_TIMESTAMP, slot);

        WORMHOLE.publishMessage{ value: msg.value }(0, abi.encode(slot, blockRoot), CONSISTENCY_LEVEL);
    }
}
