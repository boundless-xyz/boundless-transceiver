// Copyright 2025 RISC Zero, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.9;

import { reverseByteOrderUint32 } from "./Util.sol";

/// @title RISC Zero Receipt Structure
/// @notice A receipt attesting to a claim using the RISC Zero proof system
/// @dev A receipt contains two parts: a seal and a claim.
///
/// The seal is a zero-knowledge proof attesting to knowledge of a witness for the claim. The claim
/// is a set of public outputs, and for zkVM execution is the hash of a `ReceiptClaim` struct.
///
/// IMPORTANT: The `claimDigest` field must be a hash computed by the caller for verification to
/// have meaningful guarantees. Treat this similar to verifying an ECDSA signature, in that hashing
/// is a key operation in verification. The most common way to calculate this hash is to use the
/// `ReceiptClaimLib.ok(imageId, journalDigest).digest()` for successful executions.
struct Receipt {
    /// @notice The cryptographic proof data (seal)
    bytes seal;
    /// @notice Hash of the claim being proven
    bytes32 claimDigest;
}

/// @title RISC Zero Receipt Claim
/// @notice Public claims about a zkVM guest execution, such as the journal committed to by the guest
/// @dev Also includes important information such as the exit code and the starting and ending system
/// state (i.e. the state of memory). `ReceiptClaim` is a "Merkle-ized struct" supporting
/// partial openings of the underlying fields from a hash commitment to the full structure.
struct ReceiptClaim {
    /// @notice Digest of the SystemState just before execution has begun
    bytes32 preStateDigest;
    /// @notice Digest of the SystemState just after execution has completed
    bytes32 postStateDigest;
    /// @notice The exit code for the execution
    ExitCode exitCode;
    /// @notice A digest of the input to the guest
    /// @dev This field is currently unused and must be set to the zero digest
    bytes32 input;
    /// @notice Digest of the Output of the guest, including the journal
    /// and assumptions set during execution
    bytes32 output;
}

/// @title Receipt Claim Library
/// @notice Library for working with RISC Zero ReceiptClaim structures
/// @dev Provides utilities for constructing and hashing receipt claims
library ReceiptClaimLib {
    using OutputLib for Output;
    using SystemStateLib for SystemState;

    /// @notice Tag digest for ReceiptClaim structures
    bytes32 constant TAG_DIGEST = sha256("risc0.ReceiptClaim");

    // Define a constant to ensure hashing is done at compile time. Can't use the
    // SystemStateLib.digest method here because the Solidity compiler complains.
    bytes32 constant SYSTEM_STATE_ZERO_DIGEST = 0xa3acc27117418996340b84e5a90f3ef4c49d22c79e44aad822ec9c313e1eb8e2;

    /// @notice Construct a ReceiptClaim from the given imageId and journalDigest
    /// @dev Returned ReceiptClaim will represent a successful execution of the zkVM, running
    ///      the program committed by imageId and resulting in the journal specified by
    ///      journalDigest
    /// @param imageId The identifier for the guest program
    /// @param journalDigest The SHA-256 digest of the journal bytes
    /// @return A ReceiptClaim representing a successful zkVM execution
    /// @dev Input hash and postStateDigest are set to all-zeros (i.e. no committed input, or
    ///      final memory state), the exit code is (Halted, 0), and there are no assumptions
    ///      (i.e. the receipt is unconditional)
    function ok(bytes32 imageId, bytes32 journalDigest) internal pure returns (ReceiptClaim memory) {
        return ReceiptClaim(
            imageId,
            SYSTEM_STATE_ZERO_DIGEST,
            ExitCode(SystemExitCode.Halted, 0),
            bytes32(0),
            Output(journalDigest, bytes32(0)).digest()
        );
    }

    /// @notice Calculate the digest hash of a ReceiptClaim
    /// @param claim The ReceiptClaim to hash
    /// @return The SHA-256 digest of the claim
    function digest(ReceiptClaim memory claim) internal pure returns (bytes32) {
        return sha256(
            abi.encodePacked(
                TAG_DIGEST,
                // down
                claim.input,
                claim.preStateDigest,
                claim.postStateDigest,
                claim.output,
                // data
                uint32(claim.exitCode.system) << 24,
                uint32(claim.exitCode.user) << 24,
                // down.length
                uint16(4) << 8
            )
        );
    }
}

/// @title System State Structure
/// @notice Commitment to the memory state and program counter (pc) of the zkVM
/// @dev The "pre" and "post" fields of the ReceiptClaim are digests of the system state at the
///      start are stop of execution. Programs are loaded into the zkVM by creating a memory image
///      of the loaded program, and creating a system state for initializing the zkVM. This is
///      known as the "image ID"
struct SystemState {
    /// @notice Program counter
    uint32 pc;
    /// @notice Root hash of a merkle tree which confirms the integrity of the memory image
    bytes32 merkle_root;
}

/// @title System State Library
/// @notice Library for working with RISC Zero SystemState structures
/// @dev Provides utilities for hashing system states
library SystemStateLib {
    /// @notice Tag digest for SystemState structures
    bytes32 constant TAG_DIGEST = sha256("risc0.SystemState");

    /// @notice Calculate the digest hash of a SystemState
    /// @param state The SystemState to hash
    /// @return The SHA-256 digest of the state
    function digest(SystemState memory state) internal pure returns (bytes32) {
        return sha256(
            abi.encodePacked(
                TAG_DIGEST,
                // down
                state.merkle_root,
                // data
                reverseByteOrderUint32(state.pc),
                // down.length
                uint16(1) << 8
            )
        );
    }
}

/// @title Exit Code Structure
/// @notice Exit condition indicated by the zkVM at the end of the guest execution
/// @dev Exit codes have a "system" part and a "user" part. Semantically, the system part is set to
/// indicate the type of exit (e.g. halt, pause, or system split) and is directly controlled by the
/// zkVM. The user part is an exit code, similar to exit codes used in Linux, chosen by the guest
/// program to indicate additional information (e.g. 0 to indicate success or 1 to indicate an
/// error)
struct ExitCode {
    /// @notice System exit code indicating the type of exit
    SystemExitCode system;
    /// @notice User exit code chosen by the guest program
    uint8 user;
}

/// @title System Exit Code Enumeration
/// @notice Exit condition indicated by the zkVM at the end of the execution covered by this proof
/// @dev
/// `Halted` indicates normal termination of a program with an interior exit code returned from the
/// guest program. A halted program cannot be resumed.
///
/// `Paused` indicates the execution ended in a paused state with an interior exit code set by the
/// guest program. A paused program can be resumed such that execution picks up where it left
/// of, with the same memory state.
///
/// `SystemSplit` indicates the execution ended on a host-initiated system split. System split is
/// mechanism by which the host can temporarily stop execution of the execution ended in a system
/// split has no output and no conclusions can be drawn about whether the program will eventually
/// halt. System split is used in continuations to split execution into individually provable segments.
enum SystemExitCode {
    /// @notice Normal termination of a program
    Halted,
    /// @notice Execution ended in a paused state
    Paused,
    /// @notice Execution ended on a host-initiated system split
    SystemSplit
}

/// @title Output Structure
/// @notice Output field in the `ReceiptClaim`, committing to a claimed journal and assumptions list
/// @dev Verifying the integrity of a `Receipt` corresponding to a `ReceiptClaim` with a
/// non-empty assumptions list does not guarantee unconditionally any of the claims over the
/// guest execution (i.e. if the assumptions list is non-empty, then the journal digest cannot
/// be trusted to correspond to a genuine execution). The claims can be checked by additional
/// verifying a `Receipt` for every digest in the assumptions list.
struct Output {
    /// @notice Digest of the journal committed to by the guest execution
    bytes32 journalDigest;
    /// @notice Digest of the ordered list of `ReceiptClaim` digests corresponding to the
    /// calls to `env::verify` and `env::verify_integrity`
    /// @dev Verifying the integrity of a `Receipt` corresponding to a `ReceiptClaim` with a
    /// non-empty assumptions list does not guarantee unconditionally any of the claims over the
    /// guest execution (i.e. if the assumptions list is non-empty, then the journal digest cannot
    /// be trusted to correspond to a genuine execution). The claims can be checked by additional
    /// verifying a `Receipt` for every digest in the assumptions list
    bytes32 assumptionsDigest;
}

/// @title Output Library
/// @notice Library for working with RISC Zero Output structures
/// @dev Provides utilities for hashing output structures
library OutputLib {
    /// @notice Tag digest for Output structures
    bytes32 constant TAG_DIGEST = sha256("risc0.Output");

    /// @notice Calculate the digest hash of an Output
    /// @param output The Output to hash
    /// @return The SHA-256 digest of the output
    function digest(Output memory output) internal pure returns (bytes32) {
        return sha256(
            abi.encodePacked(
                TAG_DIGEST,
                // down
                output.journalDigest,
                output.assumptionsDigest,
                // down.length
                uint16(2) << 8
            )
        );
    }
}

/// @notice Error raised when cryptographic verification of the zero-knowledge proof fails
error VerificationFailed();
