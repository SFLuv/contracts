// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import "forge-std/console.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SFLUVBeraWipe} from "../src/SFLUVBeraWipe.sol";

/// Fork verification of the balanceOf-zeroing upgrade against live Bera mainnet.
contract BeraWipeForkTest is Test {
    address constant PROXY = 0x881cAd4f885c6701D8481c0eD347f6d35444eA7e;
    address constant ADMIN = 0x90496e23825aD0C8107d04671e6a27f30630Fc35;

    address[5] HOLDERS = [
        0x81274b6987DBdFDa657F9Ec54C5bfE38f13f17f0,
        0x6ad1B15A762b3a05b723d7E950729040413E516c,
        0x0f3dE0f4ce42C059165cf60d7361d8C5AE38B498,
        0x234D25189D22947C3B0a39959eEEfAc36c022BE0,
        0x32047b720a3b251448588747469d12D0F5984945
    ];

    SFLUVBeraWipe t = SFLUVBeraWipe(PROXY);

    function setUp() public {
        vm.createSelectFork("https://rpc.berachain.com");
    }

    function testForkUpgradeZeroesBalanceOf() public {
        // --- Pre-upgrade state ---
        uint256 supplyBefore = t.totalSupply();
        console.log("totalSupply before :", supplyBefore);
        uint256 sumBefore;
        for (uint256 i = 0; i < HOLDERS.length; ++i) {
            uint256 b = t.balanceOf(HOLDERS[i]);
            console.log("pre  balanceOf", HOLDERS[i], b);
            sumBefore += b;
        }
        assertGt(sumBefore, 0, "expected nonzero balances pre-upgrade");
        assertTrue(t.backingSwept(), "backing already swept on mainnet");

        // --- Upgrade ---
        SFLUVBeraWipe impl = new SFLUVBeraWipe();
        vm.prank(ADMIN);
        UUPSUpgradeable(PROXY).upgradeToAndCall(address(impl), "");

        // --- Post-upgrade ---
        for (uint256 i = 0; i < HOLDERS.length; ++i) {
            uint256 b = t.balanceOf(HOLDERS[i]);
            console.log("post balanceOf", HOLDERS[i], b);
            assertEq(b, 0, "balanceOf must be zero");
        }

        // Storage survived the upgrade (ERC-7201 namespace preserved).
        assertTrue(t.backingSwept(), "backingSwept flag preserved");
        assertTrue(t.wiped(), "wiped flag preserved");

        // Writes still locked.
        vm.expectRevert(bytes("SFLuv has migrated to CELO."));
        vm.prank(HOLDERS[0]);
        t.transfer(HOLDERS[1], 1);

        // Sweep is still one-shot.
        vm.prank(ADMIN);
        vm.expectRevert(SFLUVBeraWipe.BackingAlreadySwept.selector);
        t.sweepBacking(ADMIN);

        // --- Supply is zeroed too, so sum(balanceOf) == totalSupply holds ---
        uint256 supplyAfter = t.totalSupply();
        console.log("totalSupply after  :", supplyAfter);
        assertEq(supplyAfter, 0, "totalSupply zeroed");

        // Underlying backing is gone, so supply is unbacked either way.
        assertEq(IERC20(address(t.underlying())).balanceOf(PROXY), 0, "no backing left");
    }

    function testForkNoTransferEventsEmittedByUpgrade() public {
        SFLUVBeraWipe impl = new SFLUVBeraWipe();
        vm.recordLogs();
        vm.prank(ADMIN);
        UUPSUpgradeable(PROXY).upgradeToAndCall(address(impl), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 TRANSFER = keccak256("Transfer(address,address,uint256)");
        uint256 transfers;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == TRANSFER) transfers++;
        }
        console.log("Transfer events emitted by upgrade:", transfers);
        assertEq(transfers, 0, "upgrade emits no Transfer events - event indexers see nothing");
    }
}
