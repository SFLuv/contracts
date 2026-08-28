// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SFLUVv3} from "../src/SFLUVv3.sol";

/**
 * @notice Read-only: given a list of candidate addresses, record which currently
 *         hold MINTER_ROLE and which hold REDEEMER_ROLE on the SFLUV proxy. Used
 *         on Berachain to find the role holders to replicate onto Celo.
 *
 * Env:
 *   SFLUV_PROXY      the SFLUV proxy to read roles from (Berachain OLD_TOKEN)
 *   EXPECTED_CHAIN_ID optional chain guard
 *
 * Run (no --broadcast; reads only):
 *   forge script script/CheckRoles.s.sol:CheckRoles --sig "run(string,string)" /abs/in.json /abs/out.json --rpc-url ...
 *
 * Input  JSON: { "addresses": ["0x..."] }
 * Output JSON: { "minters": ["0x..."], "redeemers": ["0x..."] }
 */
contract CheckRoles is Script {
    function _requireExpectedChain() internal view {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        require(expected == 0 || block.chainid == expected, "EXPECTED_CHAIN_ID mismatch: wrong chain");
    }

    function run(string memory inputPath, string memory outputPath) public {
        _requireExpectedChain();

        SFLUVv3 sfluv = SFLUVv3(vm.envAddress("SFLUV_PROXY"));
        bytes32 minterRole = sfluv.MINTER_ROLE();
        bytes32 redeemerRole = sfluv.REDEEMER_ROLE();

        address[] memory addrs = vm.parseJsonAddressArray(vm.readFile(inputPath), ".addresses");

        address[] memory minterBuf = new address[](addrs.length);
        address[] memory redeemerBuf = new address[](addrs.length);
        uint256 mc;
        uint256 rc;
        for (uint256 i = 0; i < addrs.length; i++) {
            if (sfluv.hasRole(minterRole, addrs[i])) {
                minterBuf[mc++] = addrs[i];
            }
            if (sfluv.hasRole(redeemerRole, addrs[i])) {
                redeemerBuf[rc++] = addrs[i];
            }
        }

        address[] memory minters = new address[](mc);
        for (uint256 i = 0; i < mc; i++) minters[i] = minterBuf[i];
        address[] memory redeemers = new address[](rc);
        for (uint256 i = 0; i < rc; i++) redeemers[i] = redeemerBuf[i];

        string memory key = "roles";
        vm.serializeAddress(key, "minters", minters);
        string memory json = vm.serializeAddress(key, "redeemers", redeemers);
        vm.writeJson(json, outputPath);

        console.log("Checked addresses:", addrs.length);
        console.log("  MINTER holders  :", mc);
        console.log("  REDEEMER holders:", rc);
    }
}
