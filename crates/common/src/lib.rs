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

use alloy_primitives::{Address, Bytes, B256};
use alloy_sol_types::sol;
use risc0_steel::{ethereum::EthEvmInput, Commitment};

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
pub fn from_wormhole_address(wormhole_addr: B256) -> Result<Address, String> {
    // Extract the last 20 bytes from the 32-byte B256
    // This reverses the Solidity conversion: bytes32(uint256(uint160(address)))
    let bytes = wormhole_addr.as_slice();
    let (garbage_bytes, addr_bytes) = bytes.split_at(12); // Skip first 12 bytes, take last 20

    // Verify that the first 12 bytes are zero
    if garbage_bytes.iter().any(|&b| b != 0) {
        return Err(String::from("Malformed wormhole address"));
    }

    Ok(Address::from_slice(addr_bytes))
}

/// Converts a Ethereum Address to a Wormhole format address
pub fn to_wormhole_address(address: Address) -> B256 {
    let mut bytes = [0u8; 32];
    bytes[12..].copy_from_slice(address.as_slice());
    B256::from(bytes)
}

/// Converts a Wormhole format B256 address to an Ethereum Address.
pub fn from_wormhole_address_align(wormhole_addr: B256) -> Result<Address, String> {
    // Extract the last 20 bytes from the 32-byte B256
    // This reverses the Solidity conversion: bytes32(uint256(uint160(address)))
    let bytes = wormhole_addr.as_slice();
    let (garbage_bytes, addr_bytes) = bytes.split_at(12);

    // Align 12 bytes into 4 byte chunks to create 3 u32 `ints`
    let (prefix, ints, suffix) = unsafe { garbage_bytes.align_to::<u32>() };
    if prefix.iter().any(|&b| b != 0)
        || ints.iter().any(|&i| i != 0)
        || suffix.iter().any(|&b| b != 0)
    {
        return Err(String::from("Malformed wormhole address"));
    }

    Ok(Address::from_slice(addr_bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::{b256, address};

    #[test]
    fn test_from_wormhole_address_valid() {
        // Test with a valid wormhole address
        let wormhole_addr = b256!("000000000000000000000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        let expected_addr = address!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        
        let result = from_wormhole_address(wormhole_addr).unwrap();
        assert_eq!(result, expected_addr);
    }

    #[test]
    fn test_from_wormhole_address_align_valid() {
        // Test with a valid wormhole address
        let wormhole_addr = b256!("000000000000000000000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        let expected_addr = address!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        
        let result = from_wormhole_address_align(wormhole_addr).unwrap();
        assert_eq!(result, expected_addr);
    }

    #[test]
    fn test_both_functions_identical_result() {
        // Test that both functions produce identical results for valid inputs
        let wormhole_addr = b256!("000000000000000000000000bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
        let expected_addr = address!("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
        
        let result1 = from_wormhole_address(wormhole_addr).unwrap();
        let result2 = from_wormhole_address_align(wormhole_addr).unwrap();
        
        assert_eq!(result1, result2);
        assert_eq!(result1, expected_addr);
    }

    #[test]
    fn test_from_wormhole_address_invalid() {
        // Test with an invalid wormhole address (non-zero prefix)
        let wormhole_addr = b256!("000000000000000000000001aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        
        let result = from_wormhole_address(wormhole_addr);
        assert!(result.is_err());
        assert_eq!(result.unwrap_err(), "Malformed wormhole address");
    }

    #[test]
    fn test_from_wormhole_address_align_invalid() {
        // Test with an invalid wormhole address (non-zero prefix)
        let wormhole_addr = b256!("000000000000000000000001aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        
        let result = from_wormhole_address_align(wormhole_addr);
        assert!(result.is_err());
        assert_eq!(result.unwrap_err(), "Malformed wormhole address");
    }

    #[test]
    fn test_zero_address() {
        // Test with zero address
        let wormhole_addr = b256!("0000000000000000000000000000000000000000000000000000000000000000");
        let expected_addr = address!("0000000000000000000000000000000000000000");
        
        let result1 = from_wormhole_address(wormhole_addr).unwrap();
        let result2 = from_wormhole_address_align(wormhole_addr).unwrap();
        
        assert_eq!(result1, result2);
        assert_eq!(result1, expected_addr);
    }
}
