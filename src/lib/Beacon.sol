// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/// @title Beacon Library
library Beacon {
    struct BeaconConfig {
        uint256 genesisBeaconBlockTimestamp;
        uint16 beaconRootsHistoryBufferLength;
        uint64 slotSpeed;
        uint64 slotsPerEpoch;
        address beaconRootsAddress;
    }

    /// @dev Timestamp out of range for the the beacon roots precompile.
    error TimestampOutOfRange();

    /// @dev No block root is found using the beacon roots precompile.
    error NoBlockRootFound();

    /// @notice Attempts to find the block root for the given slot
    /// @dev BEACON_ROOTS returns a block root for a given parent block's timestamp. To get the block root for slot
    ///      N, you use the timestamp of slot N+1. If N+1 is not available, you use the timestamp of slot N+2, and
    ///      so on.
    /// @param slot The slot to get the block root for
    /// @return blockRoot The beacon block root of the given slot
    function findBlockRoot(uint64 slot, BeaconConfig memory config) public view returns (bytes32 blockRoot) {
        uint256 currentBlockTimestamp = config.genesisBeaconBlockTimestamp + ((slot + 1) * config.slotSpeed);

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

    /// @notice Calculates the timestamp for the start of an epoch
    /// @param epoch The epoch number to calculate the timestamp for
    /// @param config The `BeaconConfig` defining the beacon roots configuration for the current chain
    /// @return timestamp The calculated timestamp for the epoch
    function epochTimestamp(uint64 epoch, BeaconConfig memory config) external pure returns (uint256 timestamp) {
        timestamp = config.genesisBeaconBlockTimestamp + epoch * config.slotsPerEpoch * config.slotSpeed;
    }

    function ETHEREUM_MAINNET_BEACON_CONFIG() external pure returns (BeaconConfig memory beaconConfig) {
        beaconConfig = BeaconConfig({
            /// @notice Genesis beacon block timestamp for the Ethereum mainnet
            genesisBeaconBlockTimestamp: 1_606_824_023,
            /// @notice The length of the beacon roots ring buffer.
            beaconRootsHistoryBufferLength: 8191,
            /// @notice Time between beacon chain slots in seconds
            slotSpeed: 12,
            /// @notice Number of slots in an epoch
            slotsPerEpoch: 32,
            /// @notice The address of the Beacon roots contract. This is an immutable system contract so can be
            /// hard-coded
            /// @dev https://eips.ethereum.org/EIPS/eip-4788
            beaconRootsAddress: 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02
        });
    }
}
