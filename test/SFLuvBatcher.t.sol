// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {MockCoin} from "../src/MockCoin.sol";
import {SFLUVv3} from "../src/SFLUVv3.sol";
import {SFLuvBatcher} from "../src/SFLuvBatcher.sol";

/// Against the real SFLUVv3 behind its proxy, the token the batcher is built for.
contract SFLuvBatcherTest is Test {
    MockCoin internal mockCoin;
    SFLUVv3 internal sfluv;
    SFLuvBatcher internal batcher;

    address internal gov;
    address internal faucet;
    address internal stranger;
    address internal alice;
    address internal bob;
    address internal carol;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event BatchPaid(address indexed payer, uint256 count, uint256 total);

    function setUp() public {
        mockCoin = new MockCoin();
        SFLUVv3 impl = new SFLUVv3();

        gov = makeAddr("gov");
        faucet = makeAddr("faucet");
        stranger = makeAddr("stranger");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(impl.initialize, (gov, mockCoin)));
        sfluv = SFLUVv3(address(proxy));

        vm.startPrank(gov);
        sfluv.grantRole(sfluv.MINTER_ADMIN_ROLE(), gov);
        sfluv.grantRole(sfluv.MINTER_ROLE(), gov);
        vm.stopPrank();

        mockCoin.mint(gov, 2000e6);
        vm.startPrank(gov);
        mockCoin.approve(address(sfluv), 2000e6);
        sfluv.depositFor(faucet, 1000e6);
        sfluv.depositFor(stranger, 1000e6);
        vm.stopPrank();

        batcher = new SFLuvBatcher(IERC20(address(sfluv)));

        // The one-time approval the faucet Safe makes.
        vm.prank(faucet);
        sfluv.approve(address(batcher), type(uint256).max);
    }

    function _pair(address a, uint256 x, address b, uint256 y)
        internal
        pure
        returns (address[] memory to, uint256[] memory amounts)
    {
        to = new address[](2);
        amounts = new uint256[](2);
        (to[0], to[1], amounts[0], amounts[1]) = (a, b, x, y);
    }

    function test_paysEveryRecipientFromTheCaller() public {
        address[] memory to = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        (to[0], to[1], to[2]) = (alice, bob, carol);
        (amounts[0], amounts[1], amounts[2]) = (15e6, 5e6, 25e6);

        vm.expectEmit(true, true, false, true, address(sfluv));
        emit Transfer(faucet, alice, 15e6);
        vm.expectEmit(true, true, false, true, address(sfluv));
        emit Transfer(faucet, bob, 5e6);
        vm.expectEmit(true, true, false, true, address(sfluv));
        emit Transfer(faucet, carol, 25e6);
        vm.expectEmit(true, false, false, true, address(batcher));
        emit BatchPaid(faucet, 3, 45e6);

        vm.prank(faucet);
        batcher.batchTransfer(to, amounts);

        assertEq(sfluv.balanceOf(alice), 15e6);
        assertEq(sfluv.balanceOf(bob), 5e6);
        assertEq(sfluv.balanceOf(carol), 25e6);
        assertEq(sfluv.balanceOf(faucet), 1000e6 - 45e6);
        assertEq(sfluv.balanceOf(address(batcher)), 0);
    }

    function test_sameRecipientTwiceIsPaidTwice() public {
        (address[] memory to, uint256[] memory amounts) = _pair(alice, 15e6, alice, 15e6);
        vm.prank(faucet);
        batcher.batchTransfer(to, amounts);
        assertEq(sfluv.balanceOf(alice), 30e6);
    }

    /// The property that makes whitelisting it safe: a caller only ever moves
    /// its own tokens, whatever anybody else has approved.
    function test_aStrangerCannotSpendTheFaucetsAllowance() public {
        (address[] memory to, uint256[] memory amounts) = _pair(alice, 15e6, bob, 5e6);

        // The stranger approved nothing, so their own call fails...
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(batcher), 0, 15e6)
        );
        batcher.batchTransfer(to, amounts);

        // ...and once they approve, it is their own balance that moves.
        vm.prank(stranger);
        sfluv.approve(address(batcher), 20e6);
        vm.prank(stranger);
        batcher.batchTransfer(to, amounts);
        assertEq(sfluv.balanceOf(stranger), 1000e6 - 20e6);
        assertEq(sfluv.balanceOf(faucet), 1000e6);
    }

    function test_allOrNothingWhenTheBalanceRunsOut() public {
        (address[] memory to, uint256[] memory amounts) = _pair(alice, 990e6, bob, 20e6);
        vm.prank(faucet);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, faucet, 10e6, 20e6)
        );
        batcher.batchTransfer(to, amounts);
        assertEq(sfluv.balanceOf(alice), 0);
        assertEq(sfluv.balanceOf(faucet), 1000e6);
    }

    function test_allOrNothingWhenTheAllowanceRunsOut() public {
        vm.prank(faucet);
        sfluv.approve(address(batcher), 15e6);
        (address[] memory to, uint256[] memory amounts) = _pair(alice, 15e6, bob, 5e6);
        vm.prank(faucet);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(batcher), 0, 5e6)
        );
        batcher.batchTransfer(to, amounts);
        assertEq(sfluv.balanceOf(alice), 0);
    }

    function test_rejectsAnEmptyBatch() public {
        vm.prank(faucet);
        vm.expectRevert(SFLuvBatcher.EmptyBatch.selector);
        batcher.batchTransfer(new address[](0), new uint256[](0));
    }

    function test_rejectsMismatchedLengths() public {
        vm.prank(faucet);
        vm.expectRevert(abi.encodeWithSelector(SFLuvBatcher.LengthMismatch.selector, 2, 1));
        batcher.batchTransfer(new address[](2), new uint256[](1));
    }

    function test_rejectsTheZeroAddress() public {
        (address[] memory to, uint256[] memory amounts) = _pair(alice, 1e6, address(0), 1e6);
        vm.prank(faucet);
        vm.expectRevert(abi.encodeWithSelector(SFLuvBatcher.ZeroRecipient.selector, 1));
        batcher.batchTransfer(to, amounts);
    }

    function test_rejectsMoreThanTheMaximum() public {
        uint256 count = batcher.MAX_BATCH() + 1;
        vm.prank(faucet);
        vm.expectRevert(abi.encodeWithSelector(SFLuvBatcher.BatchTooLarge.selector, count));
        batcher.batchTransfer(new address[](count), new uint256[](count));
    }

    function test_paysAFullBatch() public {
        uint256 count = batcher.MAX_BATCH();
        address[] memory to = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            to[i] = address(uint160(0x1000 + i));
            amounts[i] = 1e6;
        }
        vm.prank(faucet);
        batcher.batchTransfer(to, amounts);
        assertEq(sfluv.balanceOf(faucet), 1000e6 - count * 1e6);
    }

    function test_cannotBeBuiltWithoutAToken() public {
        vm.expectRevert(SFLuvBatcher.ZeroToken.selector);
        new SFLuvBatcher(IERC20(address(0)));
    }

    function test_pinnedToItsToken() public view {
        assertEq(address(batcher.token()), address(sfluv));
    }
}
