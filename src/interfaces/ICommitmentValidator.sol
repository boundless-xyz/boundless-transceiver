// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

import { Steel } from "@steel/contracts/Steel.sol";

interface ICommitmentValidator {
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
