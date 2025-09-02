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

use alloy_primitives::{Address, B256, Bytes};
use alloy_sol_types::sol;
use risc0_steel::{Commitment, ethereum::EthEvmInput};

#[derive(serde::Serialize, serde::Deserialize)]
pub struct GuestInput {
    pub commitment: EthEvmInput,
    pub encoded_message: Bytes,
    pub contract_addr: B256,
}

impl GuestInput {
    pub fn serialize(&self) -> Result<Vec<u8>, String> {
        bincode::serialize(self).map_err(|e| format!("Failed to serialize GuestInput: {e}"))
    }

    pub fn deserialize(data: &[u8]) -> Result<Self, String> {
        bincode::deserialize(data).map_err(|e| format!("Failed to deserialize GuestInput: {e}"))
    }
}

sol! {
    interface IBoundlessTransceiver {
      /// @notice Emitted when a message is sent from this transceiver.
      /// @param recipientChain The chain ID of the recipient.
      /// @param encoded_message The encoded TransceiverMessage.
      event SendTransceiverMessage(
          uint16 recipientChain, bytes encodedMessage
      );
    }
}

sol! {
    /// @notice Journal that is committed to by the guest.
    struct Journal {
        // Commitment locks this proof to a specific block root
        // which can be verified against the BoundlessReceiver contract
        Commitment commitment;

        // The encoded TransceiverMessage that this proof commits to
        bytes encodedMessage;

        // The contract that emitted the message event
        bytes32 emitterContract;
    }
}

/// Converts a Wormhole format B256 address to an Ethereum Address.
pub fn from_wormhole_address(wormhole_addr: B256) -> Address {
    // Extract the last 20 bytes from the 32-byte B256
    // This reverses the Solidity conversion: bytes32(uint256(uint160(address)))
    let bytes = wormhole_addr.as_slice();
    let addr_bytes = &bytes[12..]; // Skip first 12 bytes, take last 20
    Address::from_slice(addr_bytes)
}

/// Converts a Ethereum Address to a Wormhole format address
pub fn to_wormhole_address(address: Address) -> B256 {
    let mut bytes = [0u8; 32];
    bytes[12..].copy_from_slice(address.as_slice());
    B256::from(bytes)
}
