// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SFLUVv2_1} from "../src/SFLUVv2_1.sol";

/**
 * @notice Upgrade the Berachain SFLUV proxy from v2 to v2_1.
 *         v2_1 adds pause + role-gated migrate(). Optional safety hatch for the
 *         pre-wipe window if you want to freeze user transfers during the Celo
 *         distribution. Not required by the migration plan.
 *
 * Env:
 *   SFLUV_V2_PROXY = 0x881cAd4f885c6701D8481c0eD347f6d35444eA7e (mainnet)
 *
 * Run:
 *   forge script script/UpgradeToV2_1.s.sol:UpgradeToV2_1 \
 *     --rpc-url https://rpc.berachain.com \
 *     --private-key $GOVERNANCE_KEY --broadcast
 */
contract UpgradeToV2_1 is Script {
    function run() public {
        address proxyAddr = vm.envAddress("SFLUV_V2_PROXY");

        vm.startBroadcast();
        SFLUVv2_1 newImpl = new SFLUVv2_1();
        UUPSUpgradeable(proxyAddr).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();

        console.log("SFLUVv2_1 impl:", address(newImpl));
        console.log("Proxy upgraded:", proxyAddr);
    }
}
