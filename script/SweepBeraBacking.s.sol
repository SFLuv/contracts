// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SFLUVBeraWipe} from "../src/SFLUVBeraWipe.sol";

/**
 * @notice Irreversibly sweep Berachain SFLUV backing assets after Celo migration
 *         has been manually verified.
 *
 * Env:
 *   SFLUV_V2_PROXY = Berachain SFLUV proxy already upgraded to SFLUVBeraWipe
 *   TREASURY       = sweep destination
 */
contract SweepBeraBacking is Script {
    function run() public {
        address proxyAddr = vm.envAddress("SFLUV_V2_PROXY");
        address treasury = vm.envAddress("TREASURY");

        vm.startBroadcast();
        SFLUVBeraWipe(proxyAddr).sweepBacking(treasury);
        vm.stopBroadcast();

        console.log("Proxy:", proxyAddr);
        console.log("Swept to:", treasury);
    }
}
