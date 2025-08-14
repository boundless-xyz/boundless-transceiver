// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/// @title Beacon Chain Utilities
/// @notice Library for interacting with Ethereum beacon chain data and block roots
/// @dev Provides utilities for finding beacon block roots and calculating epoch timestamps
library Beacon {
    struct BeaconConfig {
        uint256 genesisBeaconBlockTimestamp;
        uint16 beaconRootsHistoryBufferLength;
        uint64 slotSpeed;
        uint64 slotsPerEpoch;
        address beaconRootsAddress;
    }

    /// @notice Timestamp out of range for the the beacon roots precompile
    error TimestampOutOfRange();

    /// @notice No block root is found using the beacon roots precompile
    error NoBlockRootFound();

    /**
     * @notice Attempts to find the block root for the given slot.
     * @param genesisBlockTimestamp The timestamp of the genesis beacon block of the chain this contract is deployed
     * on. 1606824000 for Ethereum mainnet.
     * @param slot The slot to get the block root for.
     * @return blockRoot The beacon block root of the given slot.
     * @dev BEACON_ROOTS returns a block root for a given parent block's timestamp. To get the block root for slot
     *      N, you use the timestamp of slot N+1. If N+1 is not available, you use the timestamp of slot N+2, and
     *      so on.
     */
    function findBlockRoot(
        uint256 genesisBlockTimestamp,
        uint64 slot
    ) internal view returns (bytes32 blockRoot) {
        uint256 currBlockTimestamp = genesisBlockTimestamp + ((slot + 1) * 12);

        uint256 earliestBlockTimestamp = block.timestamp - (config.beaconRootsHistoryBufferLength * config.slotSpeed);
        if (currentBlockTimestamp < earliestBlockTimestamp) {
            revert TimestampOutOfRange();
        }

        while (currentBlockTimestamp <= block.timestamp) {
            (bool success, bytes memory result) =
                config.beaconRootsAddress.staticcall(abi.encode(currentBlockTimestamp));
            if (success && result.length > 0) {
                return abi.decode(result, (bytes32));
            }

            unchecked {
                currentBlockTimestamp += config.slotSpeed;
            }
        }

        revert NoBlockRootFound();
    }

    function epochTimestamp(
        uint256 genesisBlockTimestamp,
        uint64 epoch
    ) internal pure returns (uint256 timestamp) {
        timestamp =
            genesisBlockTimestamp +
            epoch *
            BLOCKS_PER_EPOCH *
            BLOCK_SPEED;
    }
}
