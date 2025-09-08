// SPDX-License-Identifier: Apache 2

pragma solidity >=0.8.8 <0.9.0;

import { ICommitmentValidator } from "../../src/interfaces/ICommitmentValidator.sol";
import { Steel, Encoding as SteelEncoding } from "@steel/contracts/Steel.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract DummyReceiver is ICommitmentValidator {
    mapping(uint64 slot => bytes32 blockRoot) private roots;

    function setBlockRoot(uint64 slot, bytes32 root) public {
        roots[slot] = root;
    }

    function blockRoot(uint64 slot, uint16) public view returns (bytes32 root, bool valid) {
        // Dummy implementation for testing purposes
        root = roots[slot];
        if (root == bytes32(0)) {
            valid = false;
        }
        valid = true;
    }

    function validateCommitment(
        Steel.Commitment memory commitment,
        uint16 confirmationLevel
    )
        external
        view
        returns (bool)
    {
        (uint240 blockID, uint16 version) = SteelEncoding.decodeVersionedID(commitment.id);
        if (version != 2) {
            revert Steel.InvalidCommitmentVersion(version);
        }

        return validateReceiverCommitment(SafeCast.toUint64(blockID), commitment.digest, confirmationLevel);
    }

    function validateReceiverCommitment(
        uint64 slot,
        bytes32 expectedBlockRoot,
        uint16 confirmationLevel
    )
        internal
        view
        returns (bool)
    {
        (bytes32 root, bool valid) = blockRoot(slot, confirmationLevel);
        return valid && (root == expectedBlockRoot);
    }
}
