// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SFLUVBeraWipe} from "../src/SFLUVBeraWipe.sol";

/**
 * @notice Phase 5a: upgrade Berachain SFLUV to the migration-lock implementation.
 *
 *         This disables user-facing writes but does not sweep backing assets.
 *         Governance can still upgrade back if Celo migration verification fails.
 *         Run `SweepBeraBacking` only after all migration steps are complete and
 *         manually verified.
 *
 * Env:
 *   SFLUV_V2_PROXY = 0x881cAd4f885c6701D8481c0eD347f6d35444eA7e (mainnet)
 *
 * Recommended preflight: simulate against a Bera mainnet fork first.
 *
 * Run:
 *   forge script script/UpgradeAndWipe.s.sol:UpgradeAndWipe \
 *     --rpc-url https://rpc.berachain.com \
 *     --private-key $GOVERNANCE_KEY --broadcast
 */
contract UpgradeAndWipe is Script {
    function run() public {
        address proxyAddr = vm.envAddress("SFLUV_V2_PROXY");

        vm.startBroadcast();
        SFLUVBeraWipe wipe = new SFLUVBeraWipe();
        UUPSUpgradeable(proxyAddr).upgradeToAndCall(address(wipe), "");
        vm.stopBroadcast();

        console.log("Wipe impl:", address(wipe));
        console.log("Proxy:", proxyAddr);
        console.log("Backing sweep not executed.");
    }
}
