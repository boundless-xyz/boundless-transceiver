#![no_main]

use alloy_primitives::{Address, FixedBytes};
use alloy_sol_types::{sol, SolValue};
use risc0_steel::{
    ethereum::{EthEvmInput, ETH_MAINNET_CHAIN_SPEC},
    Commitment, Event,
};
use risc0_zkvm::guest::env;

risc0_zkvm::guest::entry!(main);

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

fn main() {
    // Read the input from the guest environment.
    let input: EthEvmInput = env::read();
    let contract_addr: Address = env::read();
    let log_index: u32 = env::read();

    // Converts the input into a `EvmEnv` for execution.
    let env = input.into_env(&ETH_MAINNET_CHAIN_SPEC);

    // Query the `TransferSent` events of the contract and pick out the requested log index
    let event = Event::new::<INttManager::TransferSent>(&env);
    let log = &event.address(contract_addr).query()[log_index as usize];

    // Commit to this message as being from the NTT manager contract in the block committed to by the env commitment
    let journal = Journal {
        commitment: env.into_commitment(),
        nttManagerMessageDigest: log.digest,
        emitterNttManager: to_universal_address(contract_addr),
    };
    env::commit_slice(&journal.abi_encode());
}

fn to_universal_address(addr: Address) -> FixedBytes<32> {
    let addr_bytes = addr.as_slice();
    let mut padded = [0u8; 32];
    padded[12..].copy_from_slice(addr_bytes);
    FixedBytes::from(padded)
}
