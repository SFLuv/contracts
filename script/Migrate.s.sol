// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SFLUVv2_1} from "../src/SFLUVv2_1.sol";

/**
 * @notice Burn v2_1 balances in batches per a snapshot JSON.
 *         Only relevant if you upgraded to v2_1 and want to use the pause+migrate
 *         path before the wipe (or instead of it).
 *
 * Env:
 *   SFLUV_V2_PROXY = 0x881cAd4f885c6701D8481c0eD347f6d35444eA7e (mainnet)
 *
 * Snapshot JSON shape (see migration-tooling/balance-snapshot):
 *   {
 *     "block": 12345678,
 *     "totalSupply": "0x...",
 *     "addresses": ["0x...", "0x..."],
 *     "amounts":   ["0x...", "0x..."]
 *   }
 *
 * Run:
 *   forge script script/Migrate.s.sol:Migrate \
 *     --sig "run(string)" /abs/path/snapshot.json \
 *     --rpc-url https://rpc.berachain.com \
 *     --private-key $MIGRATOR_KEY --broadcast
 */
contract Migrate is Script {
    uint256 internal constant BATCH_SIZE = 100;

    function run(string memory jsonPath) public {
        address proxyAddr = vm.envAddress("SFLUV_V2_PROXY");
        SFLUVv2_1 sfluv = SFLUVv2_1(proxyAddr);

        string memory raw = vm.readFile(jsonPath);
        address[] memory addrs = vm.parseJsonAddressArray(raw, ".addresses");
        uint256[] memory amts = vm.parseJsonUintArray(raw, ".amounts");
        require(addrs.length == amts.length, "len mismatch");
        require(addrs.length > 0, "empty snapshot");

        uint256 total = addrs.length;
        console.log("Holders to migrate:", total);

        vm.startBroadcast();
        for (uint256 i = 0; i < total; i += BATCH_SIZE) {
            uint256 end = i + BATCH_SIZE > total ? total : i + BATCH_SIZE;
            uint256 sz = end - i;
            address[] memory bAddrs = new address[](sz);
            uint256[] memory bAmts = new uint256[](sz);
            for (uint256 j = 0; j < sz; ++j) {
                bAddrs[j] = addrs[i + j];
                bAmts[j] = amts[i + j];
            }
            sfluv.migrate(bAddrs, bAmts);
            console.log("Batch done. End index:", end);
        }
        vm.stopBroadcast();
    }
}
