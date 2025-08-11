// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/// @title Beacon Library
library Beacon {
    /// @notice The address of the Beacon roots contract. This is an immutable system contract so can be hard-coded
    /// @dev https://eips.ethereum.org/EIPS/eip-4788
    address internal constant BEACON_ROOTS_ADDRESS =
        0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02;

    /// @notice Genesis beacon block timestamp for the Ethereum mainnet
    uint256 public constant ETHEREUM_GENESIS_BEACON_BLOCK_TIMESTAMP =
        1_606_824_000;

    /// @notice The length of the beacon roots ring buffer.
    uint256 internal constant BEACON_ROOTS_HISTORY_BUFFER_LENGTH = 8191;

    uint256 internal constant BLOCK_SPEED = 12;

    uint256 internal constant BLOCKS_PER_EPOCH = 32;

    /// @dev Timestamp out of range for the the beacon roots precompile.
    error TimestampOutOfRange();

    /// @dev No block root is found using the beacon roots precompile.
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
    ) public view returns (bytes32 blockRoot) {
        uint256 currBlockTimestamp = genesisBlockTimestamp + ((slot + 1) * 12);

        uint256 earliestBlockTimestamp = block.timestamp -
            (BEACON_ROOTS_HISTORY_BUFFER_LENGTH * 12);
        if (currBlockTimestamp < earliestBlockTimestamp) {
            revert TimestampOutOfRange();
        }

        while (currBlockTimestamp <= block.timestamp) {
            (bool success, bytes memory result) = BEACON_ROOTS_ADDRESS
                .staticcall(abi.encode(currBlockTimestamp));
            if (success && result.length > 0) {
                return abi.decode(result, (bytes32));
            }

            unchecked {
                currBlockTimestamp += BLOCK_SPEED;
            }
        }

        revert NoBlockRootFound();
    }

    function epochTimestamp(
        uint256 genesisBlockTimestamp,
        uint64 epoch
    ) external pure returns (uint256 timestamp) {
        timestamp =
            genesisBlockTimestamp +
            epoch *
            BLOCKS_PER_EPOCH *
            BLOCK_SPEED;
    }
}
