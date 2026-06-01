// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SFLUVBeraWipe} from "../src/SFLUVBeraWipe.sol";

/**
 * @notice Upgrade Berachain SFLUV to the migration-lock implementation without
 *         sweeping backing assets.
 *
 * Env:
 *   SFLUV_V2_PROXY = Berachain SFLUV proxy
 */
contract UpgradeToBeraWipe is Script {
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
