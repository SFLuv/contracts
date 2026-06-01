// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockCoin} from "../src/MockCoin.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";
import {SFLUVBeraWipe} from "../src/SFLUVBeraWipe.sol";

contract SFLUVBeraWipeTest is Test {
    MockCoin internal honey;
    SFLUVv2 internal v2;
    SFLUVBeraWipe internal wiped;

    address internal gov;
    address internal treasury;
    address internal alice;
    address internal bob;

    function setUp() public {
        honey = new MockCoin();
        gov = makeAddr("gov");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        SFLUVv2 v2Impl = new SFLUVv2();
        ERC1967Proxy proxy = new ERC1967Proxy(address(v2Impl), abi.encodeCall(v2Impl.initialize, (gov, honey)));
        v2 = SFLUVv2(address(proxy));

        // Distribute some balances so we have meaningful state at wipe time.
        vm.startPrank(gov);
        v2.grantRole(v2.MINTER_ADMIN_ROLE(), gov);
        v2.grantRole(v2.MINTER_ROLE(), gov);
        vm.stopPrank();

        honey.mint(gov, 500 ether);
        vm.startPrank(gov);
        honey.approve(address(v2), 500 ether);
        v2.depositFor(alice, 200 ether);
        v2.depositFor(bob, 300 ether);
        vm.stopPrank();

        assertEq(honey.balanceOf(address(v2)), 500 ether);
        assertEq(v2.totalSupply(), 500 ether);
    }

    function _upgradeOnly() internal returns (SFLUVBeraWipe) {
        SFLUVBeraWipe impl = new SFLUVBeraWipe();
        vm.prank(gov);
        v2.upgradeToAndCall(address(impl), "");
        return SFLUVBeraWipe(address(v2));
    }

    // --- Wipe semantics ---

    function testUpgradeOnlyLocksWritesButDoesNotSweep() public {
        wiped = _upgradeOnly();

        assertEq(honey.balanceOf(address(wiped)), 500 ether, "proxy backing retained");
        assertEq(honey.balanceOf(treasury), 0, "treasury unchanged");
        assertFalse(wiped.backingSwept(), "sweep flag");
    }

    function testCanUpgradeBackBeforeSweep() public {
        wiped = _upgradeOnly();

        SFLUVv2 replacement = new SFLUVv2();
        vm.prank(gov);
        wiped.upgradeToAndCall(address(replacement), "");

        SFLUVv2 restored = SFLUVv2(address(wiped));
        vm.prank(alice);
        restored.transfer(bob, 10 ether);

        assertEq(restored.balanceOf(alice), 190 ether);
        assertEq(restored.balanceOf(bob), 310 ether);
        assertEq(honey.balanceOf(address(restored)), 500 ether, "proxy backing retained");
    }

    function testSweepBackingTransfersUnderlyingToTreasury() public {
        wiped = _upgradeOnly();

        vm.prank(gov);
        wiped.sweepBacking(treasury);

        assertEq(honey.balanceOf(address(wiped)), 0, "proxy drained");
        assertEq(honey.balanceOf(treasury), 500 ether, "treasury credited");
        assertTrue(wiped.backingSwept(), "sweep flag");
    }

    function testReadOnlyMethodsStillWork() public {
        wiped = _upgradeOnly();

        // Legacy state remains visible to explorers / historical tooling.
        assertEq(wiped.balanceOf(alice), 200 ether);
        assertEq(wiped.balanceOf(bob), 300 ether);
        assertEq(wiped.totalSupply(), 500 ether);
        assertEq(wiped.name(), "SFLUV V2.0");
        assertEq(wiped.symbol(), "SFLUV");
    }

    function testAllWriteMethodsRevertWithMigrationMessage() public {
        wiped = _upgradeOnly();

        string memory expected = "SFLuv has migrated to CELO.";

        vm.expectRevert(bytes(expected));
        vm.prank(alice);
        wiped.transfer(bob, 1);

        vm.expectRevert(bytes(expected));
        vm.prank(alice);
        wiped.approve(bob, 1);

        vm.expectRevert(bytes(expected));
        vm.prank(alice);
        wiped.transferFrom(bob, alice, 1);

        vm.expectRevert(bytes(expected));
        vm.prank(gov);
        wiped.depositFor(alice, 1);

        vm.expectRevert(bytes(expected));
        vm.prank(gov);
        wiped.withdrawTo(alice, 1);
    }

    function testCannotSweepBackingTwice() public {
        wiped = _upgradeOnly();

        vm.prank(gov);
        wiped.sweepBacking(treasury);

        vm.prank(gov);
        vm.expectRevert(SFLUVBeraWipe.BackingAlreadySwept.selector);
        wiped.sweepBacking(treasury);
    }

    function testUpgradeRequiresAdmin() public {
        // Deploy the impl + try to upgrade as a non-admin.
        SFLUVBeraWipe impl = new SFLUVBeraWipe();
        vm.prank(alice);
        vm.expectRevert();
        v2.upgradeToAndCall(address(impl), "");
    }

    function testSweepRequiresAdmin() public {
        wiped = _upgradeOnly();

        vm.prank(alice);
        vm.expectRevert();
        wiped.sweepBacking(treasury);
    }

    function testSweepRevertsOnZeroTreasury() public {
        wiped = _upgradeOnly();

        vm.prank(gov);
        vm.expectRevert(SFLUVBeraWipe.ZeroTreasury.selector);
        wiped.sweepBacking(address(0));
    }

    // --- Defensive: idle sweep (zero underlying) still marks backing swept ---

    function testSweepWithZeroBackingStillMarksSwept() public {
        // Drain backing first via a redeemer so the proxy holds zero HONEY.
        bytes32 redeemerAdminRole = v2.REDEEMER_ADMIN_ROLE();
        bytes32 redeemerRole = v2.REDEEMER_ROLE();
        vm.startPrank(gov);
        v2.grantRole(redeemerAdminRole, gov);
        v2.grantRole(redeemerRole, alice);
        v2.grantRole(redeemerRole, bob);
        vm.stopPrank();

        vm.prank(alice);
        v2.withdrawTo(alice, 200 ether);
        // bob still holds 300; their backing is still in the proxy. Drain that too.
        vm.prank(bob);
        v2.withdrawTo(bob, 300 ether);
        assertEq(honey.balanceOf(address(v2)), 0);

        wiped = _upgradeOnly();
        vm.prank(gov);
        wiped.sweepBacking(treasury);
        assertTrue(wiped.backingSwept());

        vm.expectRevert(bytes("SFLuv has migrated to CELO."));
        vm.prank(alice);
        wiped.transfer(bob, 1);
    }
}
