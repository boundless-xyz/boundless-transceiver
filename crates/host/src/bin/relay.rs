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

use alloy_primitives::{Address, Bytes, TxHash};
use anyhow::{Context, Result, ensure};
use clap::Parser;
use common::Journal;
use proof_builder::build_proof;
use risc0_ethereum_contracts::encode_seal;
use risc0_steel::alloy::{
    network::EthereumWallet,
    providers::ProviderBuilder,
    signers::local::PrivateKeySigner,
    sol,
    sol_types::{SolCall, SolValue},
    transports::http::reqwest::Url,
};
use risc0_zkvm::Digest;
use tracing::log;
use tracing_subscriber::EnvFilter;
use zkvm::NTT_MESSAGE_INCLUSION_ID;

sol! {
    #[sol(rpc)]
    interface IBoundlessTransceiver {
      /// @notice Process a message along with its ZK proof of inclusion in the origin chain
      /// @param encodedMessage The Wormhole encoded message containing the NTT Manager message.
      /// @param journalData The journal data that the proof commits to
      /// @param seal The opaque ZK proof seal that allows it to be verified on-chain
      /// @dev This function verifies the ZK proof, checks the commitments, then forwards the message to the NTT Manager.
      function receiveMessage(
          bytes calldata encodedMessage, bytes calldata journalData, bytes calldata seal
      ) external;

      bytes32 public immutable imageID;
    }
}

/// Relay an event from the NTT Manager contract on the Source chain to the BoundlessTransceiver contract on the Destination chain.
/// This will prove the inclusion of the event on the source chain using Steel and then send the proof to the destination chain.
#[derive(Parser)]
struct Args {
    /// Ethereum private key
    #[arg(long, env = "ETH_WALLET_PRIVATE_KEY")]
    dest_wallet_private_key: PrivateKeySigner,

    /// Ethereum RPC endpoint URL
    #[arg(long, env = "ETH_RPC_URL")]
    eth_rpc_url: Url,

    /// Destination chain RPC endpoint URL
    #[arg(long, env = "DEST_RPC_URL")]
    dest_rpc_url: Url,

    /// Beacon API endpoint URL
    ///
    /// Steel uses a beacon block commitment instead of the execution block.
    /// This allows proofs to be validated using the EIP-4788 beacon roots contract.
    #[arg(long, env = "BEACON_API_URL")]
    beacon_api_url: Url,

    /// Ethereum block to use for the beacon block commitment.
    /// Can be any finalized block after the `execution_block`
    /// Ideally is the *next* finalized block after the `execution_block`.
    #[arg(long, env = "COMMITMENT_BLOCK")]
    commitment_block: u64,

    /// Address of the NTT contract on the source chain
    #[arg(long, env = "SRC_TRANSCEIVER_ADDRESS")]
    src_transceiver_addr: Address,

    /// Address of the Boundless Transceiver contract on the destination chain
    #[arg(long, env = "DEST_TRANSCEIVER_ADDRESS")]
    dst_transceiver_addr: Address,

    /// Transaction hash of the send transaction on the source chain
    #[arg(long, env = "TX_HASH")]
    tx_hash: TxHash,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    let args = Args::try_parse()?;

    // Create an alloy provider for that private key and URL.
    let wallet = EthereumWallet::from(args.dest_wallet_private_key);
    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .connect_http(args.eth_rpc_url.clone());

    let prove_info = build_proof(
        args.tx_hash,
        args.src_transceiver_addr,
        args.eth_rpc_url,
        args.beacon_api_url,
        args.commitment_block,
    )
    .await?;

    let receipt = prove_info.receipt;
    let journal = &receipt.journal.bytes;

    // Decode and log the commitment
    let journal = Journal::abi_decode(journal).context("invalid journal")?;
    log::debug!("Steel commitment: {:?}", journal.commitment);

    // ABI encode the seal.
    let seal = encode_seal(&receipt).context("invalid receipt")?;

    // Create an alloy instance of the BoundlessTransceiver contract.
    let contract = IBoundlessTransceiver::new(args.dst_transceiver_addr, &provider);

    // Call IBoundlessTransceiver::imageID() to check that the contract has been deployed correctly
    // and ensure valid proofs will verify
    let contract_image_id = Digest::from(contract.imageID().call().await?.0);
    ensure!(
        contract_image_id == NTT_MESSAGE_INCLUSION_ID.into(),
        "Contract image ID does not match image ID being used to build proofs: {contract_image_id}, expected: {NTT_MESSAGE_INCLUSION_ID:?}",
    );

    // Call the receiveMessage function of the contract and wait for confirmation.
    log::info!(
        "Sending Tx calling {} Function of {:#}...",
        IBoundlessTransceiver::receiveMessageCall::SIGNATURE,
        contract.address()
    );
    let call_builder =
        contract.receiveMessage(receipt.journal.bytes.into(), seal.into(), Bytes::new());

    log::debug!("Send {} {}", contract.address(), call_builder.calldata());
    let pending_tx = call_builder.send().await?;
    let tx_hash = *pending_tx.tx_hash();
    let receipt = pending_tx
        .get_receipt()
        .await
        .with_context(|| format!("transaction did not confirm: {tx_hash}"))?;

    ensure!(receipt.status(), "transaction failed: {}", tx_hash);

    Ok(())
}
