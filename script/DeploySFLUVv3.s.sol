// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SFLUVv3} from "../src/SFLUVv3.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Deploy SFLUV v3 on Celo, backed by native USDC.
 *
 *         Per migration plan (Phase 3, runbook: celo-deploy-script), the Celo
 *         backing asset is native USDC. This script reads the backing address
 *         from the env so it stays parametric across networks.
 *
 * Env:
 *   BACKING_TOKEN = 0xcebA9300f2b948710d2653dD7B07f33A8B32118C (Celo native USDC)
 *                 = OR set per network; defaults below cover Celo mainnet only.
 *   GOVERNANCE    = optional override; defaults to msg.sender if not set.
 *
 * Run (Celo mainnet):
 *   forge script script/DeploySFLUVv3.s.sol:DeploySFLUVv3 \
 *     --rpc-url https://forno.celo.org \
 *     --private-key $DEPLOYER_KEY --broadcast
 */
contract DeploySFLUVv3 is Script {
    // Native USDC on Celo mainnet (chain id 42220). Used as default when
    // BACKING_TOKEN is not set in the environment.
    address constant private CELO_USDC = 0xcebA9300f2b948710d2653dD7B07f33A8B32118C;

    function run() public {
        address backingAddr = vm.envOr("BACKING_TOKEN", CELO_USDC);
        address governance = vm.envOr("GOVERNANCE", msg.sender);

        vm.startBroadcast();

        IERC20 backing = IERC20(backingAddr);
        SFLUVv3 impl = new SFLUVv3();

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(impl.initialize, (governance, backing))
        );

        vm.stopBroadcast();

        console.log("Backing token:", backingAddr);
        console.log("Governance:", governance);
        console.log("SFLUVv3 impl:", address(impl));
        console.log("SFLUVv3 UUPS proxy:", address(proxy));
    }
}
