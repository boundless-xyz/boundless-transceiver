# Boundless Transceiver Project

## Overview

The Boundless Transceiver Project provides a secure system for cross-chain messaging with cryptographic proof of inclusion in the Ethereum beacon chain. It combines RISC Zero zero-knowledge proofs with Wormhole cross-chain messaging to ensure message authenticity and integrity.

Key components:

- **BoundlessTransceiver.sol**: The main transceiver contract that sends and receives messages with ZK proof verification
- **BlockRootOracle.sol**: Main contract that manages beacon block roots with dual confirmation system
- **BeaconEmitter.sol**: Contract that emits beacon block roots via Wormhole messaging
- **Beacon.sol**: Library for interacting with Ethereum beacon chain data and block roots
- **Dual Confirmation System**: Combines RISC Zero proofs (Boundless) with Wormhole attestations for enhanced security

This project uses:

- [Forge](https://github.com/foundry-rs/foundry/blob/master/forge): Compile, test, fuzz, format, and deploy smart contracts
- [Bun](https://bun.sh/): Modern package management (instead of git submodules)
- [Forge Std](https://github.com/foundry-rs/forge-std): Testing utilities and helpful contracts
- [Solhint](https://github.com/protofire/solhint): Solidity linting

## Architecture

The system consists of two main parts:

1. **Block Root Oracle System**: Maintains and validates Ethereum beacon chain block roots with dual confirmation from both RISC Zero ZK proofs and Wormhole attestations.

2. **Boundless Transceiver**: Implements a Wormhole NTT (Native Token Transfer) transceiver that uses ZK proofs to validate message inclusion in the source chain's beacon chain before delivery.

### Boundless Transceiver Workflow

1. **Sending Messages**:

   - Messages are sent from an NTT Manager through the BoundlessTransceiver
   - The transceiver emits a `SendTransceiverMessage` event that includes the encoded message
   - Relayers listen for this event to build ZK proofs of message inclusion

2. **Receiving Messages**:
   - Relayers generate ZK proofs of message inclusion in the source chain's beacon chain
   - The proof (journalData + seal) is submitted to the destination chain's BoundlessTransceiver
   - The transceiver validates:
     - The source chain is authorized
     - The commitment is valid using the commitment validator
     - The ZK proof is valid using the RISC Zero verifier
   - If all validations pass, the message is delivered to the destination NTT Manager

### Block Root Oracle System

The BlockRootOracle maintains a secure record of Ethereum beacon chain block roots with dual confirmation:

1. **RISC Zero Proofs**: State transitions are validated using ZK proofs from the Signal-Ethereum guest program
2. **Wormhole Attestations**: Beacon block roots are also confirmed via Wormhole cross-chain messages
3. **Dual Confirmation**: Block roots require both confirmations for maximum security (TWO_OF_TWO_FLAG)

## Development

### Dependencies

This template uses Node.js packages instead of git submodules for better scalability. To add dependencies:

1. Install via package manager: `bun install dependency-name`
   - From GitHub: `bun install github:username/repo-name`
2. Add to [remappings.txt](./remappings.txt): `dependency-name=node_modules/dependency-name`

OpenZeppelin Contracts comes pre-installed as an example.

### Testing

Write tests by importing `Test` from `forge-std`. Access cheatcodes via the `vm` property. Example test in [BoundlessTransceiver.t.sol](./test/BoundlessTransceiver.t.sol).

For detailed logs, use the `-vvv` flag and [console.log](https://book.getfoundry.sh/faq?highlight=console.log#how-do-i-use-consolelog).

### Editor Support

- **VSCode**: Use with [Solidity extension](https://marketplace.visualstudio.com/items?itemName=NomicFoundation.hardhat-solidity). [Setup guide](https://book.getfoundry.sh/config/vscode)
- **(Neo)Vim**: Use `lspconfig` following these [instructions](https://github.com/NomicFoundation/hardhat-vscode/blob/development/server/README.md#neovim-lsp)

### CI/CD

GitHub Actions automatically lint and test on push/PR to `main`. Configure in [.github/workflows/ci.yml](./.github/workflows/ci.yml).

## Usage

### Common Commands

```sh
# Build
$ forge build

# Test
$ forge test
$ forge test --gas-report # CLI-based gas report
$ bun run test:coverage
$ bun run test:coverage:report  # Requires lcov: brew install lcov

# Linting & Formatting
$ bun run lint
$ forge fmt

# Deployment
$ forge script script/Deploy.s.sol --broadcast --fork-url http://localhost:8545 [--verify]
# NOTE: --verify will work iff the `etherscan` section in foundry.toml
# is specified for the dedicated rpc

# With wallet management:
$ forge script script/Deploy.s.sol --broadcast --fork-url http://localhost:8545 \
  --account <wallet-name> --froms <wallet-address> --sender <wallet-address>
```

### Project Structure

```text
├── .editorconfig
├── .gitignore
├── .solhint.json
├── AGENTS.md
├── foundry.toml
├── remappings.txt
└── README.md
```

### Smart Contract Structure

```text
src/
├── BoundlessTransceiver.sol       # Main transceiver contract for ZK-verified cross-chain messaging
├── BlockRootOracle.sol            # Main contract for beacon block root management with dual confirmation
├── BeaconEmitter.sol              # Contract for emitting beacon roots via Wormhole
├── tseth.sol                      # Core data structures (Checkpoint, ConsensusState)
├── interfaces/
│   ├── ICommitmentValidator.sol   # Interface for commitment validation
│   └── IRiscZeroVerifier.sol      # Interface for RISC Zero verifier
└── lib/
    ├── Beacon.sol                 # Beacon chain utilities
    ├── RiscZeroVerifier.sol       # RISC Zero verification structures
    └── Util.sol                   # Utility functions
```

## Related Projects

- [Signal ZKVM Guest program](https://github.com/boundless-xyz/Signal-Ethereum)

## License

This project is licensed under Apache-2.0.

[gitpod]: https://gitpod.io/#https://github.com/ignio-labs/foundry-template
[gitpod-badge]: https://img.shields.io/badge/Gitpod-Open%20in%20Gitpod-FFB45B?logo=gitpod
[gha]: https://github.com/ignio-labs/foundry-template/actions
[gha-badge]: https://github.com/ignio-labs/foundry-template/actions/workflows/ci.yml/badge.svg
[foundry]: https://getfoundry.sh/
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg
[license]: https://opensource.org/licenses/MIT
[license-badge]: https://img.shields.io/badge/License-MIT-blue.svg
