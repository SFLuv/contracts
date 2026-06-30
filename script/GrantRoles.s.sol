// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SFLUVv3} from "../src/SFLUVv3.sol";

/**
 * @notice Grant MINTER_ROLE / REDEEMER_ROLE on the SFLUV proxy to the addresses
 *         found by CheckRoles, replicating Berachain's role holders onto Celo.
 *         The broadcasting admin must hold DEFAULT_ADMIN_ROLE (to self-grant the
 *         role-admin roles) or already hold MINTER_ADMIN_ROLE / REDEEMER_ADMIN_ROLE.
 *         Idempotent: addresses that already hold a role are skipped.
 *
 * Env:
 *   SFLUV_PROXY       the SFLUV proxy to grant on (Celo NEW_TOKEN)
 *   CELO_ADMIN        broadcasting admin address (for hasRole checks)
 *   EXPECTED_CHAIN_ID optional chain guard
 *
 * Input JSON: { "minters": ["0x..."], "redeemers": ["0x..."] }
 */
contract GrantRoles is Script {
    function _requireExpectedChain() internal view {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        require(expected == 0 || block.chainid == expected, "EXPECTED_CHAIN_ID mismatch: wrong chain");
    }

    function run(string memory rolesPath) public {
        _requireExpectedChain();

        SFLUVv3 sfluv = SFLUVv3(vm.envAddress("SFLUV_PROXY"));
        address admin = vm.envAddress("CELO_ADMIN");
        bytes32 minterRole = sfluv.MINTER_ROLE();
        bytes32 redeemerRole = sfluv.REDEEMER_ROLE();
        bytes32 minterAdminRole = sfluv.MINTER_ADMIN_ROLE();
        bytes32 redeemerAdminRole = sfluv.REDEEMER_ADMIN_ROLE();

        string memory raw = vm.readFile(rolesPath);
        address[] memory minters = vm.parseJsonAddressArray(raw, ".minters");
        address[] memory redeemers = vm.parseJsonAddressArray(raw, ".redeemers");

        uint256 grantedMinters;
        uint256 grantedRedeemers;

        vm.startBroadcast();
        if (minters.length > 0 && !sfluv.hasRole(minterAdminRole, admin)) {
            sfluv.grantRole(minterAdminRole, admin); // requires DEFAULT_ADMIN_ROLE
        }
        for (uint256 i = 0; i < minters.length; i++) {
            if (!sfluv.hasRole(minterRole, minters[i])) {
                sfluv.grantRole(minterRole, minters[i]);
                grantedMinters++;
            }
        }
        if (redeemers.length > 0 && !sfluv.hasRole(redeemerAdminRole, admin)) {
            sfluv.grantRole(redeemerAdminRole, admin); // requires DEFAULT_ADMIN_ROLE
        }
        for (uint256 i = 0; i < redeemers.length; i++) {
            if (!sfluv.hasRole(redeemerRole, redeemers[i])) {
                sfluv.grantRole(redeemerRole, redeemers[i]);
                grantedRedeemers++;
            }
        }
        vm.stopBroadcast();

        console.log("MINTER: granted", grantedMinters, "of", minters.length);
        console.log("REDEEMER: granted", grantedRedeemers, "of", redeemers.length);
    }
}
