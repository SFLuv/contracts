// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {IAuthGate} from "../src/signet/IAuthGate.sol";
import {SafeBindingRegistry} from "../src/signet/SafeBindingRegistry.sol";
import {SFLuvAuthGate} from "../src/signet/SFLuvAuthGate.sol";
import {SignetAuthResolver} from "../src/signet/SignetAuthResolver.sol";

/**
 * @notice Deploy the Signet auth resolver set to Celo.
 *
 * The resolver address becomes half of every Signet key id and can never be
 * changed without orphaning keys, so this script is effectively one-shot per
 * environment. Read docs/RESOLVER-SPEC.md before running it — in particular the
 * gate decision, which is the one thing here that cannot be revisited later.
 *
 * Env:
 *   EXPECTED_CHAIN_ID   guard; 42220 for Celo mainnet
 *   GATE_OWNER          owner of the gate (SFLuv multisig). Omit to deploy with
 *                       no gate at all — permanent, so prefer a gate set to
 *                       allowAll over no gate.
 *   GATE_ALLOW_ALL      start the gate open (default false)
 *
 * Run:
 *   forge script script/DeploySignetResolver.s.sol:DeploySignetResolver \
 *     --rpc-url https://forno.celo.org --private-key $PRIVATE_KEY --broadcast
 */
contract DeploySignetResolver is Script {
    function run() public {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        require(expected == 0 || block.chainid == expected, "EXPECTED_CHAIN_ID mismatch: wrong chain");

        address gateOwner = vm.envOr("GATE_OWNER", address(0));
        bool gateAllowAll = vm.envOr("GATE_ALLOW_ALL", false);

        vm.startBroadcast();

        SafeBindingRegistry registry = new SafeBindingRegistry();

        IAuthGate gate = IAuthGate(address(0));
        if (gateOwner != address(0)) {
            gate = new SFLuvAuthGate(gateOwner, gateAllowAll, new address[](0));
        }

        SignetAuthResolver resolver = new SignetAuthResolver(registry, gate);

        vm.stopBroadcast();

        require(
            keccak256(bytes(resolver.typeAndVersion())) == keccak256("SignetAuthResolver 1.0.0"),
            "typeAndVersion outside Signet's accept-list"
        );

        console.log("chainId:  ", block.chainid);
        console.log("registry: ", address(registry));
        console.log("gate:     ", address(gate));
        console.log("resolver: ", address(resolver));
        console.log("");
        console.log("Next, on the group's chain (Ethereum mainnet), as group manager:");
        console.log(
            "  queueAuthResolver(chainId=%s, resolver=%s, requireCanonicalSubject=true)",
            block.chainid,
            address(resolver)
        );
        console.log("  ... wait removalDelay ...");
        console.log("  executeAuthResolver()");
    }
}
