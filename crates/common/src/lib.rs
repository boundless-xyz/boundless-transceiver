// Copyright 2025 Boundless, Inc.
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

use alloy_primitives::{Address, B256, FixedBytes};
use alloy_sol_types::sol;
use risc0_steel::{Commitment, ethereum::EthEvmInput};

#[derive(serde::Serialize, serde::Deserialize)]
pub struct GuestInput {
    pub commitment: EthEvmInput,
    pub contract_addr: Address,
    pub msg_digest: B256,
}

sol! {
    interface INttManager {
        /// @notice Emitted when a message is sent from the nttManager.
        /// @dev Topic0
        ///      0x3e6ae56314c6da8b461d872f41c6d0bb69317b9d0232805aaccfa45df1a16fa0.
        /// @param digest The digest of the message.
        event TransferSent(bytes32 indexed digest);
    }
}

sol! {
    /// @notice Journal that is committed to by the guest.
    struct Journal {
        // Commitment locks this proof to a specific block root
        // which can be verified against the BoundlessReceiver contract
        Commitment commitment;

        // Commits to the ntt manager message that was sent
        bytes32 nttManagerMessageDigest;
        // Commits to the NTT manager that emitted the message (wormhole encoded address)
        bytes32 emitterNttManager;
    }
}

/// Converts an Ethereum address to a Wormhole universal address format (padded to 32 bytes).
pub fn to_universal_address(addr: Address) -> FixedBytes<32> {
    let addr_bytes = addr.as_slice();
    let mut padded = [0u8; 32];
    padded[12..].copy_from_slice(addr_bytes);
    FixedBytes::from(padded)
}
