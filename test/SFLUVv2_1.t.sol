// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockCoin} from "../src/MockCoin.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";
import {SFLUVv2_1} from "../src/SFLUVv2_1.sol";

contract SFLUVv2_1Test is Test {
    MockCoin internal honey;
    SFLUVv2 internal v2; // proxy address, typed as v2 before upgrade
    SFLUVv2_1 internal v2_1; // same proxy address, typed as v2_1 after upgrade

    address internal gov;
    address internal treasury;
    address internal migrator;
    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public {
        honey = new MockCoin();

        gov = makeAddr("gov");
        treasury = makeAddr("treasury");
        migrator = makeAddr("migrator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        // Stand up the v2 proxy exactly as in production.
        SFLUVv2 v2Impl = new SFLUVv2();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(v2Impl),
            abi.encodeCall(v2Impl.initialize, (gov, honey))
        );
        v2 = SFLUVv2(address(proxy));

        // Grant roles and seed balances using the v2 ABI so we're exercising the real path.
        vm.startPrank(gov);
        v2.grantRole(v2.MINTER_ADMIN_ROLE(), gov);
        v2.grantRole(v2.MINTER_ROLE(), gov);
        v2.grantRole(v2.REDEEMER_ADMIN_ROLE(), gov);
        v2.grantRole(v2.REDEEMER_ROLE(), treasury);
        vm.stopPrank();

        honey.mint(gov, 600 ether);
        vm.startPrank(gov);
        honey.approve(address(v2), 600 ether);
        v2.depositFor(alice, 100 ether);
        v2.depositFor(bob, 200 ether);
        v2.depositFor(carol, 300 ether);
        vm.stopPrank();
    }

    function _upgradeToV2_1() internal returns (SFLUVv2_1) {
        SFLUVv2_1 newImpl = new SFLUVv2_1();
        vm.prank(gov);
        v2.upgradeToAndCall(address(newImpl), "");
        return SFLUVv2_1(address(v2));
    }

    // --- Upgrade safety: balances and roles survive ---

    function testUpgradePreservesState() public {
        v2_1 = _upgradeToV2_1();

        assertEq(v2_1.balanceOf(alice), 100 ether);
        assertEq(v2_1.balanceOf(bob), 200 ether);
        assertEq(v2_1.balanceOf(carol), 300 ether);
        assertEq(v2_1.totalSupply(), 600 ether);
        assertTrue(v2_1.hasRole(v2_1.DEFAULT_ADMIN_ROLE(), gov));
        assertTrue(v2_1.hasRole(v2_1.REDEEMER_ROLE(), treasury));
        assertEq(address(v2_1.underlying()), address(honey));
        assertFalse(v2_1.paused());
    }

    // --- Pause semantics ---

    function testPauseBlocksTransfersAndMints() public {
        v2_1 = _upgradeToV2_1();

        vm.prank(gov);
        v2_1.pause();
        assertTrue(v2_1.paused());

        // User transfer blocked.
        vm.prank(alice);
        vm.expectRevert(SFLUVv2_1.TransfersPaused.selector);
        v2_1.transfer(bob, 1 ether);

        // Wrap blocked (depositFor calls _mint -> _update with from == 0).
        honey.mint(gov, 1 ether);
        vm.startPrank(gov);
        honey.approve(address(v2_1), 1 ether);
        vm.expectRevert(SFLUVv2_1.TransfersPaused.selector);
        v2_1.depositFor(alice, 1 ether);
        vm.stopPrank();
    }

    function testPauseAllowsBurnsAndUnwraps() public {
        v2_1 = _upgradeToV2_1();

        vm.startPrank(gov);
        v2_1.pause();
        v2_1.grantRole(v2_1.REDEEMER_ROLE(), alice); // give alice the redeem right
        vm.stopPrank();

        // withdrawTo (burn + transfer of underlying) still works for REDEEMER.
        uint256 beforeBal = honey.balanceOf(alice);
        vm.prank(alice);
        v2_1.withdrawTo(alice, 100 ether);
        assertEq(honey.balanceOf(alice), beforeBal + 100 ether);
        assertEq(v2_1.balanceOf(alice), 0);
    }

    function testUnpauseRestoresTransfers() public {
        v2_1 = _upgradeToV2_1();
        vm.startPrank(gov);
        v2_1.pause();
        v2_1.unpause();
        vm.stopPrank();
        assertFalse(v2_1.paused());

        vm.prank(alice);
        v2_1.transfer(bob, 1 ether);
        assertEq(v2_1.balanceOf(bob), 201 ether);
    }

    // --- Migration ---

    function testMigrateBurnsBatchAndEmitsEvents() public {
        v2_1 = _upgradeToV2_1();
        vm.startPrank(gov);
        v2_1.pause();
        v2_1.grantRole(v2_1.MIGRATOR_ROLE(), migrator);
        vm.stopPrank();

        address[] memory holders = new address[](3);
        holders[0] = alice;
        holders[1] = bob;
        holders[2] = carol;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100 ether;
        amounts[1] = 200 ether;
        amounts[2] = 300 ether;

        for (uint256 i = 0; i < 3; ++i) {
            vm.expectEmit(true, false, false, true, address(v2_1));
            emit SFLUVv2_1.Migrated(holders[i], amounts[i]);
        }

        vm.prank(migrator);
        v2_1.migrate(holders, amounts);

        assertEq(v2_1.balanceOf(alice), 0);
        assertEq(v2_1.balanceOf(bob), 0);
        assertEq(v2_1.balanceOf(carol), 0);
        assertEq(v2_1.totalSupply(), 0);
    }

    function testMigrateRevertsOnBalanceMismatch() public {
        v2_1 = _upgradeToV2_1();
        vm.startPrank(gov);
        v2_1.pause();
        v2_1.grantRole(v2_1.MIGRATOR_ROLE(), migrator);
        vm.stopPrank();

        address[] memory holders = new address[](1);
        holders[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 999 ether; // wrong

        vm.prank(migrator);
        vm.expectRevert(
            abi.encodeWithSelector(SFLUVv2_1.BalanceMismatch.selector, alice, 999 ether, 100 ether)
        );
        v2_1.migrate(holders, amounts);
    }

    function testMigrateRequiresRole() public {
        v2_1 = _upgradeToV2_1();
        address[] memory holders = new address[](1);
        holders[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;

        vm.prank(alice);
        vm.expectRevert(); // OZ v5: AccessControlUnauthorizedAccount
        v2_1.migrate(holders, amounts);
    }

    function testMigrateRevertsOnEmptyOrMismatchedLength() public {
        v2_1 = _upgradeToV2_1();
        vm.startPrank(gov);
        v2_1.grantRole(v2_1.MIGRATOR_ROLE(), migrator);
        vm.stopPrank();

        address[] memory empty = new address[](0);
        uint256[] memory emptyAmts = new uint256[](0);
        vm.prank(migrator);
        vm.expectRevert(SFLUVv2_1.EmptyBatch.selector);
        v2_1.migrate(empty, emptyAmts);

        address[] memory holders = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        vm.prank(migrator);
        vm.expectRevert(SFLUVv2_1.LengthMismatch.selector);
        v2_1.migrate(holders, amounts);
    }

    // --- sweepUnderlying ---

    function testSweepUnderlyingRevertsWhileSupplyOutstanding() public {
        v2_1 = _upgradeToV2_1();
        // 600 ether of SFLUV still in circulation from setUp.
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(SFLUVv2_1.OutstandingSupply.selector, 600 ether));
        v2_1.sweepUnderlying(treasury);
    }

    function testSweepUnderlyingRequiresAdmin() public {
        v2_1 = _upgradeToV2_1();
        vm.prank(alice);
        vm.expectRevert();
        v2_1.sweepUnderlying(treasury);
    }

    function testSweepUnderlyingRejectsZeroAddress() public {
        v2_1 = _upgradeToV2_1();
        vm.prank(gov);
        vm.expectRevert(SFLUVv2_1.ZeroTo.selector);
        v2_1.sweepUnderlying(address(0));
    }

    // --- End-to-end: pause -> migrate -> sweep -> empty shell ---

    function testFullMigrationEndToEnd() public {
        v2_1 = _upgradeToV2_1();
        vm.startPrank(gov);
        v2_1.pause();
        v2_1.grantRole(v2_1.MIGRATOR_ROLE(), migrator);
        vm.stopPrank();

        address[] memory holders = new address[](3);
        holders[0] = alice;
        holders[1] = bob;
        holders[2] = carol;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100 ether;
        amounts[1] = 200 ether;
        amounts[2] = 300 ether;

        vm.prank(migrator);
        v2_1.migrate(holders, amounts);

        // 600 HONEY now sits in the proxy with no SFLUV backing it. withdrawTo
        // can't extract it (caller has nothing to burn); sweepUnderlying can.
        assertEq(honey.balanceOf(address(v2_1)), 600 ether);
        assertEq(v2_1.totalSupply(), 0);

        vm.prank(gov);
        v2_1.sweepUnderlying(treasury);

        assertEq(honey.balanceOf(address(v2_1)), 0);
        assertEq(honey.balanceOf(treasury), 600 ether);
        assertTrue(v2_1.paused());
    }
}
