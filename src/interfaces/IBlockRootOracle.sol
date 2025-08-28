// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

import { Steel } from "@risc0/contracts/steel/Steel.sol";

interface IBlockRootOracle {
    /**
     * @notice the root associated with the provided `slot`. If the confirmation level isn't met or the root is not
     * set, `valid` will be false
     *
     *
     * @param slot the beacon chain slot to look up
     * @param confirmationLevel the level of confirmations required for `valid` to be `true`
     */
    function blockRoot(uint64 slot, uint16 confirmationLevel) external view returns (bytes32 root, bool valid);

    // @notice Validates a Steel commitment. Only supports v2 commitments which identify the beacon block root by its
    /// slot
    /// @param commitment The commitment to validate
    /// @param confirmationLevel  A flag indicating required level of confirmation the block root must meet
    /// @return True if the commitment is valid
    function validateCommitment(
        Steel.Commitment memory commitment,
        uint16 confirmationLevel
    )
        external
        view
        returns (bool);
}
