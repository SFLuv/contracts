// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SFLUVBeraWipe} from "../src/SFLUVBeraWipe.sol";

/**
 * @notice Phase 5: upgrade Berachain SFLUV to the wipe implementation and
 *         atomically sweep underlying ERC20 to treasury.
 *
 *         POINT OF NO RETURN. Run only after Celo cutover is fully verified
 *         per migration-plan.md.
 *
 * Env:
 *   SFLUV_V2_PROXY = 0x881cAd4f885c6701D8481c0eD347f6d35444eA7e (mainnet)
 *   TREASURY       = sweep destination
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
        address treasury = vm.envAddress("TREASURY");

        vm.startBroadcast();
        SFLUVBeraWipe wipe = new SFLUVBeraWipe();
        bytes memory data = abi.encodeCall(SFLUVBeraWipe.wipeAndSweep, (treasury));
        UUPSUpgradeable(proxyAddr).upgradeToAndCall(address(wipe), data);
        vm.stopBroadcast();

        console.log("Wipe impl:", address(wipe));
        console.log("Proxy:", proxyAddr);
        console.log("Swept to:", treasury);
    }
}
