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
    // Reverts unless block.chainid matches EXPECTED_CHAIN_ID when that env var is
    // set, so a misconfigured RPC can never execute against the wrong chain.
    function _requireExpectedChain() internal view {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        require(expected == 0 || block.chainid == expected, "EXPECTED_CHAIN_ID mismatch: wrong chain");
    }

    function run() public {
        _requireExpectedChain();
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
