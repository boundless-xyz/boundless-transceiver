// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaseScript} from "./Base.s.sol";
import {BeaconEmitter} from "../src/BeaconEmitter.sol";
import {ConsensusState, Checkpoint} from "../src/tseth.sol";
import {Beacon} from "../src/lib/Beacon.sol";
import {console} from "forge-std/console.sol";

contract DeployEmitter is BaseScript {
    function run() public returns (address) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address wormhole = vm.envAddress("WORMHOLE_ADDRESS");

        vm.startBroadcast(deployerPk);
        BeaconEmitter be = new BeaconEmitter(
            wormhole,
            Beacon.ETHEREUM_GENESIS_BEACON_BLOCK_TIMESTAMP
        );
        vm.stopBroadcast();

        console.log("BeaconEmitter: ", address(be));
        return address(be);
    }
}
