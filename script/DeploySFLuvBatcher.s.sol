// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SFLuvBatcher} from "../src/SFLuvBatcher.sol";

/**
 * @notice Deploy SFLuvBatcher for the SFLUV token on Celo.
 *
 *         Not upgradeable and has no owner, so the deployer keeps no power over
 *         it once it is out.
 *
 *         Build and deploy it with FOUNDRY_PROFILE=batcher (solc 0.8.28, EVM
 *         cancun, optimizer off). The backend approves the batcher only if the
 *         deployed code's hash is the one that profile produces for the Celo
 *         token,
 *           0x744ebebb726abddb041df9e34f329a33d174d5d257b1a12ad0250b7518b855e0
 *         so any other build is refused and batching stays off.
 *
 *         After deploying:
 *           1. Add its address to the paymaster's whitelist. updateWhitelist
 *              replaces the whole list, so the call must carry every address
 *              already on it.
 *           2. Set FAUCET_BATCHER_ADDRESS on the backend. The backend approves it
 *              from the faucet Safe itself, and batches only once the paymaster
 *              reports it whitelisted and the allowance is in place.
 *
 * Env:
 *   SFLUV_TOKEN = 0x881cAd4f885c6701D8481c0eD347f6d35444eA7e (Celo mainnet, the default)
 *
 * Run (Celo mainnet):
 *   FOUNDRY_PROFILE=batcher forge script script/DeploySFLuvBatcher.s.sol:DeploySFLuvBatcher \
 *     --rpc-url https://forno.celo.org \
 *     --private-key $DEPLOYER_KEY --broadcast
 */
contract DeploySFLuvBatcher is Script {
    address constant private CELO_SFLUV = 0x881cAd4f885c6701D8481c0eD347f6d35444eA7e;

    function run() public {
        address token = vm.envOr("SFLUV_TOKEN", CELO_SFLUV);

        vm.startBroadcast();
        SFLuvBatcher batcher = new SFLuvBatcher(IERC20(token));
        vm.stopBroadcast();

        console.log("Token:", token);
        console.log("SFLuvBatcher:", address(batcher));
    }
}
