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

include!(concat!(env!("OUT_DIR"), "/methods.rs"));

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::{
        dyn_abi::SolType, network::EthereumWallet, node_bindings::Anvil, primitives::Bytes,
        providers::ProviderBuilder, signers::local::PrivateKeySigner, sol,
    };
    use common::{GuestInput, Journal, from_wormhole_address, to_wormhole_address};
    use risc0_steel::{
        Event,
        ethereum::{ETH_MAINNET_CHAIN_SPEC, EthEvmEnv},
    };
    use risc0_zkvm::{ExecutorEnv, default_executor};
    use std::sync::LazyLock;

    // A minimal contract that emits a `SendTransceiverMessage` events when `emitEvent` is called.
    sol! {
    #[sol(rpc, bytecode="6080604052348015600e575f5ffd5b5061016c8061001c5f395ff3fe608060405234801561000f575f5ffd5b5060043610610029575f3560e01c80631e08b77e1461002d575b5f5ffd5b61004061003b366004610082565b610042565b005b7f0d4a24add37c1972207e3dcfa8359764948caf868db363ee8fa1cb7f55f0a74c83838360405161007593929190610108565b60405180910390a1505050565b5f5f5f60408486031215610094575f5ffd5b833561ffff811681146100a5575f5ffd5b9250602084013567ffffffffffffffff8111156100c0575f5ffd5b8401601f810186136100d0575f5ffd5b803567ffffffffffffffff8111156100e6575f5ffd5b8660208284010111156100f7575f5ffd5b939660209190910195509293505050565b61ffff8416815260406020820152816040820152818360608301375f818301606090810191909152601f9092017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe01601019291505056fea164736f6c634300081e000a")]
    contract SendTransceiverMessageEmitter {
          event SendTransceiverMessage(
              uint16 recipientChain, bytes encodedMessage
          );

          function emitEvent(uint16 recipientChain, bytes calldata encodedMessage) external {
              emit SendTransceiverMessage(recipientChain, encodedMessage);
          }
        }
    }

    fn expected_message() -> Bytes {
        Bytes::from("Some message")
    }

    /// The test format is a 2-tuple where the first element is a vector of messages to emit
    /// and the second element is an optional expected error message. None implies there should be no error.
    /// Each test is attempting to verify the inclusion of an event containing the expected_message()
    static TEST_CASES: LazyLock<Vec<(Vec<Bytes>, Option<&'static str>)>> = LazyLock::new(|| {
        vec![
            (
                vec![],
                Some("Event for given message not contained in logs for this block"),
            ),
            (
                vec![Bytes::from("not the message")],
                Some("Event for given message not contained in logs for this block"),
            ),
            (vec![expected_message()], None),
            (vec![expected_message(), expected_message()], None),
            (
                vec![Bytes::from("not the message"), expected_message()],
                None,
            ),
        ]
    });

    #[tokio::test]
    async fn run_tests() -> anyhow::Result<()> {
        let anvil = Anvil::new().chain_id(1).spawn();
        let private_key = anvil.keys()[0].clone();
        let signer = PrivateKeySigner::from(private_key);
        let wallet = EthereumWallet::from(signer);

        let provider = ProviderBuilder::new()
            .wallet(wallet)
            .connect_http(anvil.endpoint_url());

        for (i, (messages, expected)) in TEST_CASES.iter().enumerate() {
            let contract = SendTransceiverMessageEmitter::deploy(&provider).await?;
            for msg in messages {
                contract
                    .emitEvent(3, msg.clone())
                    .send()
                    .await?
                    .get_receipt()
                    .await?;
            }
            let mut env = EthEvmEnv::builder()
                .rpc(anvil.endpoint_url())
                .chain_spec(&ETH_MAINNET_CHAIN_SPEC)
                .build()
                .await?;

            let event =
                Event::preflight::<SendTransceiverMessageEmitter::SendTransceiverMessage>(&mut env);
            let _logs = event.address(*contract.address()).query().await?;

            let evm_input = env.into_input().await?;

            let input = GuestInput {
                commitment: evm_input,
                contract_addr: to_wormhole_address(contract.address().clone()),
                encoded_message: expected_message(),
            };

            let result = tokio::task::spawn_blocking(move || {
                let env = ExecutorEnv::builder()
                    .write_frame(&input.serialize().unwrap())
                    .build()
                    .unwrap();

                default_executor().execute(env, NTT_MESSAGE_INCLUSION_ELF)
            })
            .await?;

            match result {
                Ok(info) => {
                    println!("Executed {} R0vm cycles", info.cycles());

                    if let Some(expected) = expected {
                        panic!("Test case {i}: Expected error: {expected}, but got success");
                    }
                    let journal = Journal::abi_decode(&info.journal.bytes)?;
                    assert_eq!(
                        from_wormhole_address(journal.emitterContract),
                        *contract.address()
                    );
                    assert_eq!(journal.encodedMessage, expected_message());
                }
                Err(e) => {
                    if let Some(expected) = expected {
                        assert!(
                            e.to_string().contains(expected),
                            "Test case {i}: Expected error: {expected}, but got: {}",
                            e
                        );
                    } else {
                        panic!("Test case {i}: Unexpected error: {}", e);
                    }
                }
            }
        }

        Ok(())
    }
}
