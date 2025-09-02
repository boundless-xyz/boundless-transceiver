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
#![no_main]

use alloy_sol_types::SolValue;
use common::{from_wormhole_address, GuestInput, IBoundlessTransceiver, Journal};
use risc0_steel::{ethereum::ETH_MAINNET_CHAIN_SPEC, Event};
use risc0_zkvm::guest::env;

risc0_zkvm::guest::entry!(main);

fn main() {
    let input_bytes: Vec<u8> = env::read_frame();
    let input = GuestInput::deserialize(&input_bytes).expect("Failed to deserialize input");

    // Converts the input into a `EvmEnv` for execution.
    let env = input.commitment.into_env(&ETH_MAINNET_CHAIN_SPEC);

    // Query the `SendTransceiverMessage` events of the contract and ensure it contains the expected message digest
    let event = Event::new::<IBoundlessTransceiver::SendTransceiverMessage>(&env);
    let logs = &event
        .address(from_wormhole_address(input.contract_addr))
        .query();
    assert!(
        logs.iter()
            .any(|log| log.encodedMessage == input.encoded_message),
        "Event for given message not contained in logs for this block",
    );

    // Commit to this message as being from the NTT manager contract in the block committed to by the env commitment
    let journal = Journal {
        commitment: env.into_commitment(),
        encodedMessage: input.encoded_message,
        emitterContract: input.contract_addr,
    };
    env::commit_slice(&journal.abi_encode());
}
