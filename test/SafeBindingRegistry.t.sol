// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SafeBindingRegistry} from "../src/signet/SafeBindingRegistry.sol";

import {MockSafe} from "./mocks/SignetMocks.sol";

/// @dev Any contract can claim to own anybody. This is why the nominated Safe
///      cannot be the one that authorises a binding.
contract LyingSafe {
    function isOwner(address) external pure returns (bool) {
        return true;
    }
}

contract SafeBindingRegistryTest is Test {
    SafeBindingRegistry internal registry;

    address internal alice;
    uint256 internal alicePk;
    address internal mallory;
    MockSafe internal aliceSafe;
    MockSafe internal aliceOtherSafe;

    event SafeBound(address indexed account, address indexed safe, address indexed previousSafe);

    function setUp() public {
        registry = new SafeBindingRegistry();
        (alice, alicePk) = makeAddrAndKey("alice");
        mallory = makeAddr("mallory");
        aliceSafe = new MockSafe(alice);
        aliceOtherSafe = new MockSafe(alice);
    }

    function _sign(uint256 pk, address account, address safe, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(registry.BIND_TYPEHASH(), account, safe, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            registry.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    // --- the account binds itself -------------------------------------------

    function test_bind_byAccount() public {
        vm.expectEmit(true, true, true, true);
        emit SafeBound(alice, address(aliceSafe), address(0));

        vm.prank(alice);
        registry.bind(address(aliceSafe));

        assertEq(registry.safeFor(alice), address(aliceSafe));
    }

    function test_bind_rejectsNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(SafeBindingRegistry.NotAnOwner.selector, mallory, address(aliceSafe)));
        vm.prank(mallory);
        registry.bind(address(aliceSafe));
    }

    function test_bind_rejectsZeroSafe() public {
        vm.expectRevert(SafeBindingRegistry.ZeroAddress.selector);
        vm.prank(alice);
        registry.bind(address(0));
    }

    function test_bind_rejectsSafeWithNoCode() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.bind(makeAddr("not a contract"));
    }

    function test_bind_manyAccountsToOneSafe() public {
        address second = makeAddr("second");
        aliceSafe.setOwner(second, true);

        vm.prank(alice);
        registry.bind(address(aliceSafe));
        vm.prank(second);
        registry.bind(address(aliceSafe));

        assertEq(registry.safeFor(alice), registry.safeFor(second));
    }

    function test_safeFor_unboundIsZero() public view {
        assertEq(registry.safeFor(mallory), address(0));
    }

    // --- nobody binds on anyone else's behalf -------------------------------

    /// The vulnerability that retired the first version of this contract: it
    /// accepted `msg.sender == safe` and then asked that same contract whether
    /// it owned the account. Anyone could pin any unbound EOA to an address of
    /// their choosing, and write-once made it permanent.
    function test_bind_lyingSafeCannotSquatAnAccount() public {
        LyingSafe attacker = new LyingSafe();

        // The attacker is free to bind *itself* to its own lying contract —
        // that is its own identity, and worth nothing to anyone else.
        vm.prank(address(attacker));
        registry.bind(address(attacker));
        assertEq(registry.safeFor(address(attacker)), address(attacker));

        // What it cannot do is write a binding for an address it does not
        // control. There is no longer any function that lets it try.
        assertEq(registry.safeFor(alice), address(0), "alice must remain unbound");
    }

    function test_bind_thirdPartyCannotBindAnotherAccount() public {
        // There is no longer any function that takes someone else's address
        // without their signature. The nearest attempt binds the caller.
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(SafeBindingRegistry.NotAnOwner.selector, mallory, address(aliceSafe)));
        registry.bind(address(aliceSafe));

        assertEq(registry.safeFor(alice), address(0));
    }

    /// Even a real Safe that has added the victim as an owner without their
    /// consent — permitted by Safe — cannot bind them.
    function test_bind_realSafeCannotBindAnUnwillingOwner() public {
        MockSafe malloryySafe = new MockSafe(mallory);
        malloryySafe.setOwner(alice, true); // Safe lets you add anyone

        vm.prank(address(malloryySafe));
        vm.expectRevert();
        registry.bind(address(malloryySafe));

        assertEq(registry.safeFor(alice), address(0), "alice must remain unbound");
    }

    // --- relayed binding, authorised by signature ---------------------------

    function test_bindWithSignature_relayerPaysAccountAuthorises() public {
        bytes memory sig = _sign(alicePk, alice, address(aliceSafe), 0, block.timestamp + 1 hours);

        vm.prank(mallory); // any relayer
        registry.bindWithSignature(alice, address(aliceSafe), block.timestamp + 1 hours, sig);

        assertEq(registry.safeFor(alice), address(aliceSafe));
        assertEq(registry.nonces(alice), 1);
    }

    function test_bindWithSignature_rejectsForgedSignature() public {
        (, uint256 malloryPk) = makeAddrAndKey("mallory-key");
        bytes memory sig = _sign(malloryPk, alice, address(aliceSafe), 0, block.timestamp + 1 hours);

        vm.expectRevert(SafeBindingRegistry.InvalidSignature.selector);
        registry.bindWithSignature(alice, address(aliceSafe), block.timestamp + 1 hours, sig);
    }

    function test_bindWithSignature_rejectsReplay() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(alicePk, alice, address(aliceSafe), 0, deadline);

        registry.bindWithSignature(alice, address(aliceSafe), deadline, sig);

        vm.expectRevert(SafeBindingRegistry.InvalidSignature.selector);
        registry.bindWithSignature(alice, address(aliceSafe), deadline, sig);
    }

    function test_bindWithSignature_rejectsExpired() public {
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _sign(alicePk, alice, address(aliceSafe), 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(SafeBindingRegistry.SignatureExpired.selector, deadline));
        registry.bindWithSignature(alice, address(aliceSafe), deadline, sig);
    }

    /// A signature for one Safe cannot be redirected to another.
    function test_bindWithSignature_isBoundToTheNamedSafe() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(alicePk, alice, address(aliceSafe), 0, deadline);

        vm.expectRevert(SafeBindingRegistry.InvalidSignature.selector);
        registry.bindWithSignature(alice, address(aliceOtherSafe), deadline, sig);
    }

    /// A signature for this registry cannot be replayed against another
    /// deployment of it — the domain separator pins the verifying contract.
    function test_bindWithSignature_isBoundToThisRegistry() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(alicePk, alice, address(aliceSafe), 0, deadline);

        SafeBindingRegistry other = new SafeBindingRegistry();
        vm.expectRevert(SafeBindingRegistry.InvalidSignature.selector);
        other.bindWithSignature(alice, address(aliceSafe), deadline, sig);
    }

    // --- rebinding, by the account alone ------------------------------------

    /// The stuck-binding problem the first version had: an account bound to the
    /// wrong Safe, or one it has since left, had no recourse forever.
    function test_rebind_byAccount() public {
        vm.prank(alice);
        registry.bind(address(aliceSafe));

        vm.expectEmit(true, true, true, true);
        emit SafeBound(alice, address(aliceOtherSafe), address(aliceSafe));

        vm.prank(alice);
        registry.bind(address(aliceOtherSafe));

        assertEq(registry.safeFor(alice), address(aliceOtherSafe));
    }

    function test_rebind_stillRequiresOwnership() public {
        vm.prank(alice);
        registry.bind(address(aliceSafe));

        MockSafe strangersSafe = new MockSafe(mallory);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeBindingRegistry.NotAnOwner.selector, alice, address(strangersSafe)));
        registry.bind(address(strangersSafe));

        assertEq(registry.safeFor(alice), address(aliceSafe), "failed rebind must not disturb the binding");
    }

    function test_rebind_toTheSameSafeReverts() public {
        vm.prank(alice);
        registry.bind(address(aliceSafe));

        vm.expectRevert(
            abi.encodeWithSelector(SafeBindingRegistry.AlreadyBoundTo.selector, alice, address(aliceSafe))
        );
        vm.prank(alice);
        registry.bind(address(aliceSafe));
    }

    /// Rebinding is not a way to reach a wallet you do not already own, so it
    /// grants nothing. A third party still cannot move someone else's binding.
    function test_rebind_cannotBeDoneByAThirdParty() public {
        vm.prank(alice);
        registry.bind(address(aliceSafe));

        LyingSafe attacker = new LyingSafe();
        vm.prank(address(attacker));
        registry.bind(address(attacker)); // binds only itself

        assertEq(registry.safeFor(alice), address(aliceSafe), "alice's binding is untouched");
    }
}
