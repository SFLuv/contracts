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
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(v2Impl),
            abi.encodeCall(v2Impl.initialize, (gov, honey))
        );
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

    function _upgradeAndWipe() internal returns (SFLUVBeraWipe) {
        SFLUVBeraWipe impl = new SFLUVBeraWipe();
        bytes memory initData = abi.encodeCall(SFLUVBeraWipe.wipeAndSweep, (treasury));
        vm.prank(gov);
        v2.upgradeToAndCall(address(impl), initData);
        return SFLUVBeraWipe(address(v2));
    }

    // --- Wipe semantics ---

    function testUpgradeAndWipeSweepsUnderlyingToTreasury() public {
        wiped = _upgradeAndWipe();

        assertEq(honey.balanceOf(address(wiped)), 0, "proxy drained");
        assertEq(honey.balanceOf(treasury), 500 ether, "treasury credited");
        assertTrue(wiped.wiped(), "wiped flag");
    }

    function testReadOnlyMethodsStillWork() public {
        wiped = _upgradeAndWipe();

        // Legacy state remains visible to explorers / historical tooling.
        assertEq(wiped.balanceOf(alice), 200 ether);
        assertEq(wiped.balanceOf(bob), 300 ether);
        assertEq(wiped.totalSupply(), 500 ether);
        assertEq(wiped.name(), "SFLUV V2.0");
        assertEq(wiped.symbol(), "SFLUV");
    }

    function testAllWriteMethodsRevertWithMigrationMessage() public {
        wiped = _upgradeAndWipe();

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

    function testCannotWipeTwice() public {
        wiped = _upgradeAndWipe();

        vm.prank(gov);
        vm.expectRevert(SFLUVBeraWipe.AlreadyWiped.selector);
        wiped.wipeAndSweep(treasury);
    }

    function testWipeRequiresAdmin() public {
        // Deploy the impl + try to upgrade as a non-admin.
        SFLUVBeraWipe impl = new SFLUVBeraWipe();
        bytes memory initData = abi.encodeCall(SFLUVBeraWipe.wipeAndSweep, (treasury));
        vm.prank(alice);
        vm.expectRevert();
        v2.upgradeToAndCall(address(impl), initData);
    }

    function testWipeRevertsOnZeroTreasury() public {
        SFLUVBeraWipe impl = new SFLUVBeraWipe();
        bytes memory initData = abi.encodeCall(SFLUVBeraWipe.wipeAndSweep, (address(0)));
        vm.prank(gov);
        vm.expectRevert(); // proxy bubbles the ZeroTreasury revert
        v2.upgradeToAndCall(address(impl), initData);
    }

    // --- Defensive: idle wipe (zero underlying) still locks the contract ---

    function testWipeWithZeroBackingStillLocks() public {
        // Drain backing first via a redeemer so the proxy holds zero HONEY.
        vm.prank(gov);
        v2.grantRole(v2.REDEEMER_ADMIN_ROLE(), gov);
        vm.prank(gov);
        v2.grantRole(v2.REDEEMER_ROLE(), alice);
        vm.prank(alice);
        v2.withdrawTo(alice, 200 ether);
        // bob still holds 300; their backing is still in the proxy. Drain that too.
        vm.prank(gov);
        v2.grantRole(v2.REDEEMER_ROLE(), bob);
        vm.prank(bob);
        v2.withdrawTo(bob, 300 ether);
        assertEq(honey.balanceOf(address(v2)), 0);

        wiped = _upgradeAndWipe();
        assertTrue(wiped.wiped());

        vm.expectRevert(bytes("SFLuv has migrated to CELO."));
        vm.prank(alice);
        wiped.transfer(bob, 1);
    }
}
