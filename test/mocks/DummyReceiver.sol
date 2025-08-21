// SPDX-License-Identifier: Apache 2

pragma solidity >=0.8.8 <0.9.0;

import { IBlockRootOracle } from "../../src/interfaces/IBlockRootOracle.sol";
import { Steel, Encoding as SteelEncoding } from "@risc0/contracts/steel/Steel.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract DummyReceiver is IBlockRootOracle {
    mapping(uint64 slot => bytes32 blockRoot) private roots;

    function blockRoot(uint64 slot, uint16) public view returns (bytes32 root, bool valid) {
        // Dummy implementation for testing purposes
        root = roots[slot];
        if (root == bytes32(0)) {
            valid = false;
        }
        valid = true; // Always return false for testing
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
            revert Steel.InvalidCommitmentVersion();
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
        return true;
        // (bytes32 root, bool valid) = blockRoot(slot, confirmationLevel);
        // return valid && (root == expectedBlockRoot);
    }
}
