// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import { BaseScript } from "./Base.s.sol";
import { BlockRootOracle } from "../src/BlockRootOracle.sol";
import { ConsensusState, Checkpoint } from "../src/tseth.sol";
import { console } from "forge-std/console.sol";
import { Beacon } from "../src/lib/Beacon.sol";

contract DeployReceiver is BaseScript {
    function run() public returns (address) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        bytes32 imageID = vm.envBytes32("IMAGE_ID");
        uint24 permissibleTimespan = uint24(vm.envUint("PERMISSIBLE_TIMESPAN"));
        address beaconEmitter = vm.envAddress("BEACON_EMITTER_ADDRESS");
        uint16 emitterChainId = uint16(vm.envUint("EMITTER_CHAIN_ID"));
        address verifier = vm.envAddress("VERIFIER_ADDRESS");
        address wormhole = vm.envAddress("WORMHOLE_ADDRESS");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address superAdmin = vm.envAddress("SUPER_ADMIN_ADDRESS");

        uint64 currentJustifiedEpoch = uint64(vm.envUint("CURRENT_JUSTIFIED_EPOCH"));
        bytes32 currentJustifiedRoot = vm.envBytes32("CURRENT_JUSTIFIED_ROOT");
        uint64 finalizedEpoch = uint64(vm.envUint("FINALIZED_EPOCH"));
        bytes32 finalizedRoot = vm.envBytes32("FINALIZED_ROOT");

        ConsensusState memory startingState = ConsensusState({
            currentJustifiedCheckpoint: Checkpoint({ epoch: currentJustifiedEpoch, root: currentJustifiedRoot }),
            finalizedCheckpoint: Checkpoint({ epoch: finalizedEpoch, root: finalizedRoot })
        });

        vm.startBroadcast(deployerPk);
        BlockRootOracle br = new BlockRootOracle(
            startingState,
            permissibleTimespan,
            verifier,
            imageID,
            wormhole,
            beaconEmitter,
            emitterChainId,
            admin,
            superAdmin,
            Beacon.ETHEREUM_MAINNET_BEACON_CONFIG()
        );
        vm.stopBroadcast();

        console.log("BlockRootOracle: ", address(br));
        return address(br);
    }
}
