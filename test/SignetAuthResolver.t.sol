// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IAuthGate} from "../src/signet/IAuthGate.sol";
import {ISafeBindingRegistry} from "../src/signet/ISafeBindingRegistry.sol";
import {SafeBindingRegistry} from "../src/signet/SafeBindingRegistry.sol";
import {SFLuvAuthGate} from "../src/signet/SFLuvAuthGate.sol";
import {SignetAuthResolver} from "../src/signet/SignetAuthResolver.sol";

import {
    DenyAllGate,
    DirtyWordRegistry,
    GasBurnerCallee,
    HugeReturnCallee,
    MockRegistry,
    MockSafe,
    ModuleMembershipGate,
    RevertingCallee,
    SenderSensitiveSafe,
    ShortReturnCallee
} from "./mocks/SignetMocks.sol";

contract SignetAuthResolverTest is Test {
    SafeBindingRegistry internal registry;
    SignetAuthResolver internal resolver;

    address internal alice;
    address internal aliceSecondDevice;
    address internal bob;
    MockSafe internal aliceSafe;

    function setUp() public {
        registry = new SafeBindingRegistry();
        resolver = new SignetAuthResolver(registry, IAuthGate(address(0))); // open

        alice = makeAddr("alice");
        aliceSecondDevice = makeAddr("aliceSecondDevice");
        bob = makeAddr("bob");

        aliceSafe = new MockSafe(alice);
    }

    function _subject(address safe) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(safe)));
    }

    // --- The version string is a protocol constant -------------------------

    /// Signet's accept-list (node/resolver.go) is compiled into every node.
    /// Any other string — an SFLuv-branded one included — fails auth network
    /// wide, so pin the bytes.
    function test_typeAndVersion_matchesSignetAcceptList() public view {
        assertEq(resolver.typeAndVersion(), "SignetAuthResolver 1.0.0");
    }

    // --- Happy path --------------------------------------------------------

    function test_resolve_boundOwner() public {
        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));

        (bool ok, bytes32 subject) = resolver.resolve(alice);
        assertTrue(ok);
        assertEq(subject, _subject(address(aliceSafe)));
    }

    /// The whole point of resolving to the wallet: a second credential that is
    /// also an owner lands on the *same* subject, so one person is one
    /// principal rather than one-per-login.
    function test_resolve_twoOwnersConvergeOnOneSubject() public {
        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));

        aliceSafe.setOwner(aliceSecondDevice, true);
        vm.prank(aliceSecondDevice);
        registry.bind(aliceSecondDevice, address(aliceSafe));

        (bool ok1, bytes32 s1) = resolver.resolve(alice);
        (bool ok2, bytes32 s2) = resolver.resolve(aliceSecondDevice);
        assertTrue(ok1);
        assertTrue(ok2);
        assertEq(s1, s2);
    }

    /// Succession: the wallet keeps its identity when the credential that
    /// created it is removed, and the removed credential stops authenticating.
    function test_resolve_survivesOwnerRotation() public {
        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));
        aliceSafe.setOwner(aliceSecondDevice, true);
        vm.prank(aliceSecondDevice);
        registry.bind(aliceSecondDevice, address(aliceSafe));

        aliceSafe.setOwner(alice, false);

        (bool oldOk,) = resolver.resolve(alice);
        assertFalse(oldOk, "removed owner must stop authenticating");

        (bool newOk, bytes32 subject) = resolver.resolve(aliceSecondDevice);
        assertTrue(newOk);
        assertEq(subject, _subject(address(aliceSafe)), "subject unchanged across succession");
    }

    // --- Denials -----------------------------------------------------------

    function test_resolve_zeroAccount() public view {
        (bool ok, bytes32 subject) = resolver.resolve(address(0));
        assertFalse(ok);
        assertEq(subject, bytes32(0));
    }

    function test_resolve_unbound() public view {
        (bool ok,) = resolver.resolve(bob);
        assertFalse(ok);
    }

    /// The registry only ever nominates. If the Safe disagrees, the Safe wins —
    /// this is the property that stops a bad registry granting an identity.
    function test_resolve_registryCannotGrantIdentity() public {
        MockRegistry rogue = new MockRegistry();
        SignetAuthResolver r = new SignetAuthResolver(rogue, IAuthGate(address(0)));

        // Rogue registry points Bob at Alice's Safe.
        rogue.set(bob, address(aliceSafe));

        (bool ok,) = r.resolve(bob);
        assertFalse(ok, "isOwner must veto a registry entry the account has no claim on");
    }

    function test_resolve_safeWithNoCode() public {
        MockRegistry rogue = new MockRegistry();
        SignetAuthResolver r = new SignetAuthResolver(rogue, IAuthGate(address(0)));
        rogue.set(alice, makeAddr("neverDeployed"));

        (bool ok,) = r.resolve(alice);
        assertFalse(ok);
    }

    // --- resolve() must never revert ---------------------------------------

    function test_resolve_neverRevertsOnHostileSafe() public {
        MockRegistry rogue = new MockRegistry();
        SignetAuthResolver r = new SignetAuthResolver(rogue, IAuthGate(address(0)));

        address[4] memory hostiles = [
            address(new RevertingCallee()),
            address(new ShortReturnCallee()),
            address(new HugeReturnCallee()),
            address(new GasBurnerCallee())
        ];

        for (uint256 i = 0; i < hostiles.length; ++i) {
            rogue.set(alice, hostiles[i]);
            (bool ok, bytes32 subject) = r.resolve(alice);
            assertFalse(ok, "hostile safe must deny, not revert");
            assertEq(subject, bytes32(0));
        }
    }

    function test_resolve_neverRevertsOnHostileRegistry() public {
        address[5] memory registries = [
            address(new RevertingCallee()),
            address(new ShortReturnCallee()),
            address(new HugeReturnCallee()),
            address(new GasBurnerCallee()),
            address(new DirtyWordRegistry())
        ];

        for (uint256 i = 0; i < registries.length; ++i) {
            SignetAuthResolver r = new SignetAuthResolver(ISafeBindingRegistry(registries[i]), IAuthGate(address(0)));
            (bool ok, bytes32 subject) = r.resolve(alice);
            assertFalse(ok);
            assertEq(subject, bytes32(0));
        }
    }

    /// A registry address that was never deployed: staticcall succeeds with
    /// empty returndata, which the length check turns into a denial. This is
    /// the case a typed call or try/catch would get wrong.
    function test_resolve_neverRevertsOnCodelessRegistry() public {
        SignetAuthResolver r =
            new SignetAuthResolver(ISafeBindingRegistry(makeAddr("notAContract")), IAuthGate(address(0)));
        (bool ok,) = r.resolve(alice);
        assertFalse(ok);
    }

    function test_resolve_neverRevertsOnHostileGate() public {
        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));

        address[4] memory gates = [
            address(new RevertingCallee()),
            address(new ShortReturnCallee()),
            address(new HugeReturnCallee()),
            address(new GasBurnerCallee())
        ];

        for (uint256 i = 0; i < gates.length; ++i) {
            SignetAuthResolver r = new SignetAuthResolver(registry, IAuthGate(gates[i]));
            (bool ok,) = r.resolve(alice);
            assertFalse(ok, "a gate that cannot answer must fail closed");
        }
    }

    /// The gas cap is what keeps a hostile callee from pushing the call past a
    /// node's eth_call limit — nodes do not agree on that limit, and a
    /// disagreement there splits the vote.
    function test_resolve_boundedGasAgainstBurner() public {
        MockRegistry rogue = new MockRegistry();
        SignetAuthResolver r = new SignetAuthResolver(rogue, IAuthGate(address(0)));
        rogue.set(alice, address(new GasBurnerCallee()));

        uint256 before = gasleft();
        (bool ok,) = r.resolve(alice);
        uint256 used = before - gasleft();

        assertFalse(ok);
        assertLt(used, 400_000, "resolve must stay far below any node eth_call cap");
    }

    // --- Determinism: no branching on msg.sender ---------------------------

    function test_resolve_isSenderIndependent() public {
        MockRegistry rogue = new MockRegistry();
        SignetAuthResolver r = new SignetAuthResolver(rogue, IAuthGate(address(0)));
        rogue.set(alice, address(new SenderSensitiveSafe()));

        // The node pins from = 0x0; every other caller must see the same answer.
        (bool okZero, bytes32 subjectZero) = r.resolve(alice);

        vm.prank(makeAddr("someNode"));
        (bool okA, bytes32 subjectA) = r.resolve(alice);

        vm.prank(makeAddr("anotherNode"));
        (bool okB, bytes32 subjectB) = r.resolve(alice);

        // The resolver reads the same state regardless of who asks. (The callee
        // here varies with *its* caller, which is always the resolver.)
        assertEq(okA, okZero);
        assertEq(okB, okZero);
        assertEq(subjectA, subjectZero);
        assertEq(subjectB, subjectZero);
    }

    // --- Gate --------------------------------------------------------------

    function test_gate_deniesUnlistedAndAdmitsListed() public {
        address[] memory seed = new address[](1);
        seed[0] = alice;
        SFLuvAuthGate gate = new SFLuvAuthGate(address(this), false, seed);
        SignetAuthResolver gated = new SignetAuthResolver(registry, gate);

        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));
        aliceSafe.setOwner(bob, true);
        vm.prank(bob);
        registry.bind(bob, address(aliceSafe));

        (bool aliceOk,) = gated.resolve(alice);
        (bool bobOk,) = gated.resolve(bob);
        assertTrue(aliceOk);
        assertFalse(bobOk, "unlisted account must be denied while the gate is closed");

        gate.setAllowAll(true);
        (bobOk,) = gated.resolve(bob);
        assertTrue(bobOk, "allowAll opens the gate without changing the resolver");
    }

    function test_gate_deniesEveryoneWhenClosed() public {
        SignetAuthResolver gated = new SignetAuthResolver(registry, new DenyAllGate());
        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));

        (bool ok,) = gated.resolve(alice);
        assertFalse(ok);
    }

    function test_gate_neverChangesTheSubject() public {
        address[] memory seed = new address[](1);
        seed[0] = alice;
        SFLuvAuthGate gate = new SFLuvAuthGate(address(this), false, seed);
        SignetAuthResolver gated = new SignetAuthResolver(registry, gate);

        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));

        (, bytes32 gatedSubject) = gated.resolve(alice);
        (, bytes32 openSubject) = resolver.resolve(alice);
        assertEq(gatedSubject, openSubject, "admission policy must not touch subject derivation");
    }

    // --- Gate delegate (the rollout path) --------------------------------

    /// The delegate exists so admission can move from a curated list to a
    /// membership question answered by chain state, without a new resolver.
    function test_delegate_admitsWhatTheAllowlistDoesNot() public {
        SFLuvAuthGate gate = new SFLuvAuthGate(address(this), false, new address[](0));
        SignetAuthResolver gated = new SignetAuthResolver(registry, gate);

        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));

        (bool ok,) = gated.resolve(alice);
        assertFalse(ok, "empty allowlist, no delegate: nobody gets in");

        address module = makeAddr("communityModule");
        gate.setDelegate(new ModuleMembershipGate(registry, module));

        (ok,) = gated.resolve(alice);
        assertFalse(ok, "delegate must still deny a Safe without the module");

        aliceSafe.setModule(module, true);
        (bool okNow, bytes32 subject) = gated.resolve(alice);
        assertTrue(okNow, "membership answered from chain state, no list to curate");
        assertEq(subject, _subject(address(aliceSafe)), "delegated policy must not touch the subject");
    }

    /// Widening-only: a delegate adds a way in, it never vetoes the allowlist.
    function test_delegate_cannotVetoTheAllowlist() public {
        address[] memory seed = new address[](1);
        seed[0] = alice;
        SFLuvAuthGate gate = new SFLuvAuthGate(address(this), false, seed);
        SignetAuthResolver gated = new SignetAuthResolver(registry, gate);

        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));

        // A delegate that denies everyone, and a Safe with no module either way.
        gate.setDelegate(new ModuleMembershipGate(registry, makeAddr("someModule")));

        (bool ok,) = gated.resolve(alice);
        assertTrue(ok, "allowlisted account must survive a denying delegate");
    }

    /// A broken delegate must not take the allowlist down with it. The gate
    /// checks locally first and swallows the delegate's failure.
    function test_delegate_hostileDelegateIsIsolated() public {
        address[] memory seed = new address[](1);
        seed[0] = alice;

        address[3] memory hostiles =
            [address(new RevertingCallee()), address(new GasBurnerCallee()), address(new ShortReturnCallee())];

        for (uint256 i = 0; i < hostiles.length; ++i) {
            SFLuvAuthGate gate = new SFLuvAuthGate(address(this), false, seed);
            SignetAuthResolver gated = new SignetAuthResolver(registry, gate);
            gate.setDelegate(IAuthGate(hostiles[i]));

            if (i == 0) {
                vm.prank(alice);
                registry.bind(alice, address(aliceSafe));
                aliceSafe.setOwner(bob, true);
                vm.prank(bob);
                registry.bind(bob, address(aliceSafe));
            }

            (bool aliceOk,) = gated.resolve(alice);
            assertTrue(aliceOk, "allowlist must keep working behind a broken delegate");

            (bool bobOk,) = gated.resolve(bob);
            assertFalse(bobOk, "a delegate that cannot answer admits nobody");
        }
    }

    function test_delegate_clearedReturnsToAllowlistOnly() public {
        SFLuvAuthGate gate = new SFLuvAuthGate(address(this), false, new address[](0));
        SignetAuthResolver gated = new SignetAuthResolver(registry, gate);

        address module = makeAddr("communityModule");
        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));
        aliceSafe.setModule(module, true);
        gate.setDelegate(new ModuleMembershipGate(registry, module));

        (bool ok,) = gated.resolve(alice);
        assertTrue(ok);

        gate.setDelegate(IAuthGate(address(0)));
        (ok,) = gated.resolve(alice);
        assertFalse(ok, "clearing the delegate leaves the allowlist as the whole policy");
    }

    function test_delegate_onlyOwnerMaySet() public {
        SFLuvAuthGate gate = new SFLuvAuthGate(address(this), false, new address[](0));
        vm.expectRevert();
        vm.prank(bob);
        gate.setDelegate(IAuthGate(makeAddr("anything")));
    }

    /// The whole chain — resolver -> gate -> delegate -> Safe — has to fit
    /// inside the resolver's 100k cap on the gate call.
    function test_delegate_wholeChainFitsTheGasCap() public {
        SFLuvAuthGate gate = new SFLuvAuthGate(address(this), false, new address[](0));
        SignetAuthResolver gated = new SignetAuthResolver(registry, gate);

        address module = makeAddr("communityModule");
        vm.prank(alice);
        registry.bind(alice, address(aliceSafe));
        aliceSafe.setModule(module, true);
        gate.setDelegate(new ModuleMembershipGate(registry, module));

        uint256 before = gasleft();
        (bool ok,) = gated.resolve(alice);
        uint256 used = before - gasleft();

        assertTrue(ok, "two nested reads must still fit the budget");
        assertLt(used, 100_000, "resolve with a delegated policy stays well inside any node cap");
    }

    function test_constructor_rejectsZeroRegistry() public {
        vm.expectRevert(SignetAuthResolver.RegistryRequired.selector);
        new SignetAuthResolver(ISafeBindingRegistry(address(0)), IAuthGate(address(0)));
    }
}
