// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SFLUVv3} from "../src/SFLUVv3.sol";

/**
 * @notice Phase 3 step 9: distribute SFLUV v3 balances on Celo by calling
 *         depositFor for each holder, using the migration snapshot JSON.
 *
 *         This is the "use ERC20 mint/deposit internals" path from the runbook:
 *         each call transfers `amount` underlying USDC from the distributor to
 *         the v3 proxy and credits SFLUV to the holder. Total supply and backing
 *         stay coherent throughout.
 *
 * Env:
 *   SFLUV_V3_PROXY = address of v3 on Celo
 *   DISTRIBUTOR    = address that holds USDC and will sign the batch
 *
 * Preconditions (operator):
 *   - DISTRIBUTOR holds at least sum(amounts) USDC on Celo.
 *   - DISTRIBUTOR has approved SFLUV_V3_PROXY to spend that USDC.
 *   - DISTRIBUTOR has been granted MINTER_ROLE on v3.
 *
 * Run:
 *   forge script script/DistributeBatch.s.sol:DistributeBatch \
 *     --sig "run(string)" /abs/path/snapshot.json \
 *     --rpc-url https://forno.celo.org \
 *     --private-key $DISTRIBUTOR_KEY --broadcast
 */
contract DistributeBatch is Script {
    function run(string memory jsonPath) public {
        address v3 = vm.envAddress("SFLUV_V3_PROXY");
        address distributor = vm.envAddress("DISTRIBUTOR");
        SFLUVv3 sfluv = SFLUVv3(v3);
        IERC20 backing = IERC20(address(sfluv.underlying()));

        string memory raw = vm.readFile(jsonPath);
        address[] memory addrs = vm.parseJsonAddressArray(raw, ".addresses");
        uint256[] memory amts = vm.parseJsonUintArray(raw, ".amounts");
        require(addrs.length == amts.length, "len mismatch");
        require(addrs.length > 0, "empty snapshot");

        // Preflight: sum, backing balance, allowance, idempotency.
        uint256 total = 0;
        for (uint256 i = 0; i < amts.length; ++i) total += amts[i];

        require(backing.balanceOf(distributor) >= total, "distributor: insufficient USDC");
        require(backing.allowance(distributor, v3) >= total, "distributor: USDC allowance < total");
        for (uint256 i = 0; i < addrs.length; ++i) {
            require(sfluv.balanceOf(addrs[i]) == 0, "recipient already has SFLUV; refusing to double-credit");
        }

        console.log("Recipients:", addrs.length);
        console.log("Total USDC to wrap:", total);

        vm.startBroadcast();
        for (uint256 i = 0; i < addrs.length; ++i) {
            sfluv.depositFor(addrs[i], amts[i]);
        }
        vm.stopBroadcast();

        console.log("Distribution complete.");
    }
}
