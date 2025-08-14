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

use alloy_primitives::{Address, Bytes};
use alloy_sol_types::sol;
use risc0_steel::{Commitment, ethereum::EthEvmInput};

#[derive(serde::Serialize, serde::Deserialize)]
pub struct GuestInput {
    pub commitment: EthEvmInput,
    pub encoded_message: Bytes,
    pub contract_addr: Address,
}

impl GuestInput {
    pub fn serialize(&self) -> Result<Vec<u8>, String> {
        bincode::serialize(self).map_err(|e| format!("Failed to serialize GuestInput: {}", e))
    }

    pub fn deserialize(data: &[u8]) -> Result<Self, String> {
        bincode::deserialize(data).map_err(|e| format!("Failed to deserialize GuestInput: {}", e))
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
        address emitterContract;
    }
}
