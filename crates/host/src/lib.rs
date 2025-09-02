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

use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::TransactionReceipt;
use alloy_primitives::{Address, TxHash};
use alloy_sol_types::SolEvent;
use anyhow::{Context, Result, ensure};
use common::{GuestInput, IBoundlessTransceiver, to_wormhole_address};
use risc0_steel::ethereum::ETH_MAINNET_CHAIN_SPEC;
use risc0_steel::{
    Event, alloy::transports::http::reqwest::Url, ethereum::EthEvmEnv, host::BlockNumberOrTag,
};
use risc0_zkvm::{ExecutorEnv, ProveInfo, ProverOpts, VerifierContext, default_prover};
use tokio::task;
use zkvm::NTT_MESSAGE_INCLUSION_ELF;

pub async fn build_input(
    tx_hash: TxHash,
    contract_addr: Address,
    rpc_url: Url,
    beacon_api_url: Url,
    commitment_block: u64,
) -> Result<Vec<u8>> {
    let provider = ProviderBuilder::new().connect_http(rpc_url.clone());

    // Get the transaction receipt
    let receipt: TransactionReceipt = provider
        .get_transaction_receipt(tx_hash)
        .await?
        .context("No transaction found with given tx_hash")?;

    let execution_block = receipt
        .block_number
        .context("Tx was not included in a block")?;
    ensure!(
        commitment_block >= execution_block,
        "commitment block must be greater than or equal to execution block"
    );

    // Find the first matching event emitted by the contract in the transaction receipt
    // NOTE(willem): This assumes that only a single NTT message is being sent in the transaction
    // it is possible we might want to support handling multiple per tx in the future
    let encoded_message = receipt
        .logs()
        .iter()
        .find_map(|log| {
            if log.address() == contract_addr {
                IBoundlessTransceiver::SendTransceiverMessage::decode_log(&log.inner)
                    .ok()
                    .map(|event| event.encodedMessage.clone())
            } else {
                None
            }
        })
        .context("No SendTransceiverMessage event found in transaction receipt")?;

    ensure!(
        !encoded_message.is_empty(),
        "No encoded message found in SendTransceiverMessage event"
    );

    let builder = EthEvmEnv::builder()
        .rpc(rpc_url)
        .block_number_or_tag(BlockNumberOrTag::Number(execution_block))
        .beacon_api(beacon_api_url)
        .commitment_block_number_or_tag(BlockNumberOrTag::Number(commitment_block));

    let mut env = builder.chain_spec(&ETH_MAINNET_CHAIN_SPEC).build().await?;

    let event = Event::preflight::<IBoundlessTransceiver::SendTransceiverMessage>(&mut env);
    let logs = event.address(contract_addr).query().await?;
    ensure!(
        logs.iter()
            .any(|log| { log.encodedMessage == encoded_message }),
        "Log with digest {encoded_message} not found in contract {contract_addr}, block {execution_block}",
    );

    // Finally, construct the input from the environment.
    let evm_input = env.into_input().await?;

    let input = GuestInput {
        commitment: evm_input,
        contract_addr: to_wormhole_address(contract_addr),
        encoded_message,
    };

    let input_bytes = input.serialize().map_err(anyhow::Error::msg)?;

    // Produce the env_in by applying the length prefix as read_frame expects
    let mut guest_env_in = Vec::<u8>::new();
    guest_env_in.extend_from_slice(&input_bytes.len().to_le_bytes());
    guest_env_in.extend_from_slice(&input_bytes);

    Ok(guest_env_in)
}

pub async fn build_proof(
    tx_hash: TxHash,
    contract_addr: Address,
    rpc_url: Url,
    beacon_api_url: Url,
    commitment_block: u64,
) -> Result<ProveInfo> {
    let env_input = build_input(
        tx_hash,
        contract_addr,
        rpc_url,
        beacon_api_url,
        commitment_block,
    )
    .await?;

    // Create the RISC Zero proof
    let prove_info = task::spawn_blocking(move || {
        let env = ExecutorEnv::builder()
            .write_slice(&env_input)
            .build()
            .unwrap();

        default_prover().prove_with_ctx(
            env,
            &VerifierContext::default(),
            NTT_MESSAGE_INCLUSION_ELF,
            &ProverOpts::groth16(),
        )
    })
    .await?
    .context("failed to create proof")?;

    Ok(prove_info)
}
