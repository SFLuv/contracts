// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SFLUVv3} from "../src/SFLUVv3.sol";

/**
 * @notice Pre-distribution safety check: wrap a tiny amount of backing into SFLUV
 *         and immediately unwrap it, proving the backing can be BOTH locked and
 *         recovered before minting all balances. Reverts (failing the migration
 *         step) if either direction fails or the backing is not fully restored —
 *         so we never lock up backing we cannot get back out.
 *
 * Env:
 *   SFLUV_V3_PROXY          new token proxy (Celo)
 *   DISTRIBUTOR             distributor address (MINTER; holds backing)
 *   WRAP_CHECK_AMOUNT       optional, default 1 (underlying base units)
 *   WRAP_CHECK_REDEEMER_KEY optional REDEEMER private key. Defaults to the
 *                           broadcast key, in which case the distributor must
 *                           also hold REDEEMER_ROLE.
 *   EXPECTED_CHAIN_ID       optional chain guard
 */
contract WrapUnwrapCheck is Script {
    function _requireExpectedChain() internal view {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        require(expected == 0 || block.chainid == expected, "EXPECTED_CHAIN_ID mismatch: wrong chain");
    }

    function run() public {
        _requireExpectedChain();

        SFLUVv3 sfluv = SFLUVv3(vm.envAddress("SFLUV_V3_PROXY"));
        IERC20 backing = IERC20(address(sfluv.underlying()));
        address minter = vm.envAddress("DISTRIBUTOR");
        uint256 amount = vm.envOr("WRAP_CHECK_AMOUNT", uint256(1));
        require(amount > 0, "WRAP_CHECK_AMOUNT must be > 0");

        uint256 redeemerPk = vm.envOr("WRAP_CHECK_REDEEMER_KEY", uint256(0));
        address redeemer = redeemerPk == 0 ? minter : vm.addr(redeemerPk);

        require(backing.balanceOf(minter) >= amount, "distributor backing balance < check amount");

        uint256 minterBackingBefore = backing.balanceOf(minter);
        uint256 redeemerSfluvBefore = sfluv.balanceOf(redeemer);

        // Wrap: distributor (MINTER) deposits backing, crediting SFLUV to the redeemer.
        vm.startBroadcast();
        if (backing.allowance(minter, address(sfluv)) < amount) {
            backing.approve(address(sfluv), amount);
        }
        require(sfluv.depositFor(redeemer, amount), "depositFor (wrap) returned false");
        vm.stopBroadcast();

        require(sfluv.balanceOf(redeemer) == redeemerSfluvBefore + amount, "wrap did not credit SFLUV");

        // Unwrap: redeemer (REDEEMER) withdraws, returning backing to the distributor.
        if (redeemerPk == 0) {
            vm.startBroadcast();
        } else {
            vm.startBroadcast(redeemerPk);
        }
        require(sfluv.withdrawTo(minter, amount), "withdrawTo (unwrap) returned false");
        vm.stopBroadcast();

        require(sfluv.balanceOf(redeemer) == redeemerSfluvBefore, "unwrap did not burn the wrapped SFLUV");
        require(backing.balanceOf(minter) == minterBackingBefore, "backing not fully restored after roundtrip");

        console.log("Wrap/unwrap roundtrip OK: backing is recoverable.");
        console.log("  amount  :", amount);
        console.log("  minter  :", minter);
        console.log("  redeemer:", redeemer);
    }
}
