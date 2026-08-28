// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SFLUVBeraWipe} from "../src/SFLUVBeraWipe.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";

/**
 * @notice Verification of the deprecated SFLUV proxy against live Berachain state.
 *
 *         Set BERA_RPC_URL to run; the suite no-ops without it so the default
 *         `forge test` stays offline.
 *
 *         This was written as a preflight — assert nonzero balances, upgrade,
 *         assert they read zero — and the deployment overtook it. The upgrade is
 *         live (impl `0xaf91a0…c03f`), so the assertions now run the other way:
 *         confirm the deployed contract reads zero, and confirm the legacy
 *         balances are still sitting in storage behind it.
 *
 *         That second point is the one that matters operationally. The zeroing is
 *         display-only: no burn ran, no Transfer events were emitted, so
 *         event-derived indexers still carry the legacy balances and the real
 *         burn pass via `SFLUVv2_1.migrate()` remains available and still owed.
 */
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
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BERA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    /// The deployed state: every RPC-polled read is zero, which is what stopped
    /// old Citizen Wallet clients on Bera showing a balance.
    function test_liveProxyReadsZero() public view {
        if (!forked) return;

        assertEq(t.totalSupply(), 0, "supply must read zero");
        for (uint256 i = 0; i < HOLDERS.length; ++i) {
            assertEq(t.balanceOf(HOLDERS[i]), 0, "holder must read zero");
        }

        // Metadata is deliberately left intact for explorers.
        assertEq(t.name(), "SFLUV V2.0");
        assertEq(t.symbol(), "SFLUV");

        // Backing is gone, so the supply the contract used to report was
        // unbacked regardless of what it said.
        assertTrue(t.backingSwept(), "backing already swept");
        assertEq(IERC20(address(t.underlying())).balanceOf(PROXY), 0, "no backing left");
    }

    function test_writesStayLockedAndSweepIsSpent() public {
        if (!forked) return;

        vm.expectRevert(bytes("SFLuv has migrated to CELO."));
        vm.prank(HOLDERS[0]);
        t.transfer(HOLDERS[1], 1);

        vm.prank(ADMIN);
        vm.expectRevert(SFLUVBeraWipe.BackingAlreadySwept.selector);
        t.sweepBacking(ADMIN);
    }

    /// The zeroing hid the balances; it did not burn them. Upgrading back to a
    /// normal ERC20 implementation brings the real holder balances straight
    /// back, which is what makes the deferred burn pass still possible — and
    /// what makes it still outstanding.
    function test_legacyBalancesAreStillInStorage() public {
        if (!forked) return;

        SFLUVv2 replacement = new SFLUVv2();
        vm.prank(ADMIN);
        UUPSUpgradeable(PROXY).upgradeToAndCall(address(replacement), "");

        SFLUVv2 restored = SFLUVv2(PROXY);
        uint256 sum;
        for (uint256 i = 0; i < HOLDERS.length; ++i) {
            sum += restored.balanceOf(HOLDERS[i]);
        }
        assertGt(sum, 0, "legacy balances were never cleared, only hidden");
        assertGt(restored.totalSupply(), 0, "supply was never burned");
    }

    /// No Transfer events means event-derived indexers (Ponder, subgraphs,
    /// explorer holder tables) never saw the zeroing and still report the
    /// legacy balances.
    function test_upgradeEmitsNoTransferEvents() public {
        if (!forked) return;

        SFLUVBeraWipe impl = new SFLUVBeraWipe();
        vm.recordLogs();
        vm.prank(ADMIN);
        UUPSUpgradeable(PROXY).upgradeToAndCall(address(impl), "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != transferTopic, "upgrade must emit no Transfer events");
            }
        }
    }
}
