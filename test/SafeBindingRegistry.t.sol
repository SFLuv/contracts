// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SafeBindingRegistry} from "../src/signet/SafeBindingRegistry.sol";

import {MockSafe} from "./mocks/SignetMocks.sol";

contract SafeBindingRegistryTest is Test {
    SafeBindingRegistry internal registry;

    address internal alice;
    address internal mallory;
    MockSafe internal aliceSafe;
    MockSafe internal aliceOtherSafe;

    event SafeBound(address indexed account, address indexed safe, address indexed boundBy);

    function setUp() public {
        registry = new SafeBindingRegistry();
        alice = makeAddr("alice");
        mallory = makeAddr("mallory");
        aliceSafe = new MockSafe(alice);
        aliceOtherSafe = new MockSafe(alice);
    }

    function test_bind_byAccount() public {
        vm.expectEmit(true, true, true, true);
        emit SafeBound(alice, address(aliceSafe), alice);

        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));

        assertEq(registry.safeFor(alice), address(aliceSafe));
    }

    /// The normal production path: the wallet binds its own owner, as a
    /// sponsored user operation through the Citizen Wallet CommunityModule.
    function test_bind_bySafe() public {
        vm.prank(address(aliceSafe));
        registry.bind(alice, address(aliceSafe));

        assertEq(registry.safeFor(alice), address(aliceSafe));
    }

    /// Nobody binds on anyone else's behalf. Without this, a third party could
    /// permanently pin an account to a Safe it owns but did not choose — and
    /// write-once means there is no taking it back.
    function test_bind_rejectsThirdParty() public {
        vm.expectRevert(abi.encodeWithSelector(SafeBindingRegistry.NotSelfAuthorized.selector, mallory));
        vm.prank(mallory);
        registry.bind(alice, address(aliceSafe));
    }

    function test_bind_rejectsNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(SafeBindingRegistry.NotAnOwner.selector, mallory, address(aliceSafe)));
        vm.prank(mallory);
        registry.bind(mallory, address(aliceSafe));
    }

    /// A binding is a live key namespace. Re-pointing one moves an identity,
    /// which is exactly the hijack the per-resolver namespacing exists to stop.
    function test_bind_isWriteOnce() public {
        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));

        vm.expectRevert(abi.encodeWithSelector(SafeBindingRegistry.AlreadyBound.selector, alice, address(aliceSafe)));
        vm.prank(alice);
        registry.bind(alice, address(aliceOtherSafe));

        assertEq(registry.safeFor(alice), address(aliceSafe));
    }

    /// Not even the Safe can move an existing binding.
    function test_bind_writeOnceHoldsAgainstTheSafeItself() public {
        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));

        vm.expectRevert(abi.encodeWithSelector(SafeBindingRegistry.AlreadyBound.selector, alice, address(aliceSafe)));
        vm.prank(address(aliceOtherSafe));
        registry.bind(alice, address(aliceOtherSafe));
    }

    function test_bind_manyAccountsToOneSafe() public {
        address second = makeAddr("second");
        aliceSafe.setOwner(second, true);

        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));
        vm.prank(second);
        registry.bind(second, address(aliceSafe));

        assertEq(registry.safeFor(alice), registry.safeFor(second));
    }

    function test_bind_rejectsZeroAddresses() public {
        vm.expectRevert(SafeBindingRegistry.ZeroAddress.selector);
        vm.prank(alice);
        registry.bind(address(0), address(aliceSafe));

        vm.expectRevert(SafeBindingRegistry.ZeroAddress.selector);
        vm.prank(alice);
        registry.bind(alice, address(0));
    }

    function test_safeFor_unboundIsZero() public view {
        assertEq(registry.safeFor(mallory), address(0));
    }
}
