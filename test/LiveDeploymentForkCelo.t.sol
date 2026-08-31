// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {ISafe} from "../src/signet/ISafe.sol";
import {ISignetAuthResolver} from "../src/signet/ISignetAuthResolver.sol";
import {SafeBindingRegistry} from "../src/signet/SafeBindingRegistry.sol";
import {SFLuvAuthGate} from "../src/signet/SFLuvAuthGate.sol";

/// @dev The squat that retired the first registry: a contract that claims to
///      own everybody. Kept here so the live deployment is checked against it.
contract LyingSafe {
    function isOwner(address) external pure returns (bool) {
        return true;
    }
}

/**
 * @notice End-to-end against the contracts actually deployed on Celo, not
 *         freshly constructed ones. Proves the enrolment flow admits the
 *         designated test wallet, that each step is individually required, and
 *         that a third party cannot write a binding for someone else.
 *
 * Run: CELO_RPC_URL=https://forno.celo.org forge test --match-path test/LiveDeploymentForkCelo.t.sol
 */
contract LiveDeploymentForkCeloTest is Test {
    ISignetAuthResolver constant RESOLVER = ISignetAuthResolver(0x903409cB9248b1f0047c5F967a3db8E03Df3E11a);
    SafeBindingRegistry constant REGISTRY = SafeBindingRegistry(0xd35A40c49c6FAfD8a3B193146726A7B3a97e9BBa);
    SFLuvAuthGate constant GATE = SFLuvAuthGate(0x78B405B629e7c27F81d7dF3dCEcC097f58B47053);

    address constant GATE_OWNER = 0x762F96819a7705448843E96D63D638Ec2f39403B;
    address constant SAFE = 0x3ADbca066E6B04F00DC9D110aF39875d892848Ff;
    address constant EOA = 0x4aB013e7537F9F419127c6C787ca0951158cF40b;

    function _signBind(uint256 pk, address account, address safe, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(REGISTRY.BIND_TYPEHASH(), account, safe, REGISTRY.nonces(account), deadline)
        );
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = REGISTRY.eip712Domain();
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifying
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function setUp() public {
        string memory url = vm.envOr("CELO_RPC_URL", string(""));
        vm.skip(bytes(url).length == 0);
        vm.createSelectFork(url);
    }

    function test_liveWiringIsWhatWeDocumented() public view {
        assertEq(RESOLVER.typeAndVersion(), "SignetAuthResolver 1.0.0");
        assertEq(GATE.owner(), GATE_OWNER);
        assertFalse(GATE.allowAll());
        assertEq(address(GATE.delegate()), address(0));
        assertTrue(ISafe(SAFE).isOwner(EOA), "test wallet's owner must still be its owner");
    }

    /// The staff allowlist entry already written to the gate survived swapping
    /// the registry and resolver underneath it.
    function test_theTestEoaIsAlreadyAllowlisted() public view {
        assertTrue(GATE.allowlisted(EOA));
        assertTrue(GATE.isAllowed(EOA));
    }

    function test_todayTheTestWalletIsDeniedBecauseItIsUnbound() public view {
        assertEq(REGISTRY.safeFor(EOA), address(0), "nothing bound yet");
        (bool ok, bytes32 subject) = RESOLVER.resolve(EOA);
        assertFalse(ok);
        assertEq(subject, bytes32(0));
    }

    function test_bindResolvesToTheSafe() public {
        vm.prank(EOA);
        REGISTRY.bind(SAFE);

        (bool ok, bytes32 subject) = RESOLVER.resolve(EOA);
        assertTrue(ok, "enrolled wallet must resolve");
        assertEq(address(uint160(uint256(subject))), SAFE, "subject must be the Safe");
    }

    /// The production enrolment path: the user signs, a relayer pays.
    function test_bindWithSignatureIsTheGaslessPath() public {
        (address signer, uint256 pk) = makeAddrAndKey("a wallet owner");
        vm.prank(SAFE);
        // Give the fork a Safe whose owner we hold the key for, via the real
        // Safe's own owner management.
        (bool added,) = SAFE.call(abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", signer, uint256(1)));
        vm.assume(added);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signBind(pk, signer, SAFE, deadline);

        // Submitted by an unrelated relayer, who pays the gas.
        vm.prank(makeAddr("relayer"));
        REGISTRY.bindWithSignature(signer, SAFE, deadline, sig);

        assertEq(REGISTRY.safeFor(signer), SAFE);
        assertEq(REGISTRY.nonces(signer), 1);
    }

    /// The relayer's identity is not consulted, so the Safe itself may still
    /// submit the binding through the CommunityModule — the sponsored rail the
    /// wallet already uses. Only the Safe's *authority* was removed; its role
    /// as a payer is unchanged, and `execSponsored` needs no modification.
    function test_theSafeItselfMayStillRelay() public {
        (address signer, uint256 pk) = makeAddrAndKey("another wallet owner");
        vm.prank(SAFE);
        (bool added,) = SAFE.call(abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", signer, uint256(1)));
        vm.assume(added);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signBind(pk, signer, SAFE, deadline);

        // The Safe is the caller. It carries no authority here; the signature does.
        vm.prank(SAFE);
        REGISTRY.bindWithSignature(signer, SAFE, deadline, sig);

        assertEq(REGISTRY.safeFor(signer), SAFE);
    }

    /// ... and relaying does not let the Safe bind an owner who did not sign.
    function test_theSafeCannotRelayWithoutASignature() public {
        vm.prank(SAFE);
        vm.expectRevert();
        REGISTRY.bindWithSignature(EOA, SAFE, block.timestamp + 1 hours, hex"");

        assertEq(REGISTRY.safeFor(EOA), address(0));
    }

    /// The vulnerability that retired the previous registry, checked against
    /// the live replacement.
    function test_aLyingSafeCannotSquatTheTestEoa() public {
        LyingSafe attacker = new LyingSafe();

        vm.prank(address(attacker));
        REGISTRY.bind(address(attacker)); // binds only itself

        assertEq(REGISTRY.safeFor(EOA), address(0), "the test EOA must remain unbound");

        vm.prank(EOA);
        REGISTRY.bind(SAFE);
        (bool ok, bytes32 subject) = RESOLVER.resolve(EOA);
        assertTrue(ok);
        assertEq(address(uint160(uint256(subject))), SAFE, "subject is the real Safe, not the attacker's");
    }

    function test_aStrangerCannotBindTheTestWalletsSafe() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        REGISTRY.bind(SAFE);
    }

    function test_theAccountCanCorrectAWrongBinding() public {
        LyingSafe wrong = new LyingSafe();

        vm.prank(EOA);
        REGISTRY.bind(address(wrong)); // a mistake the user could make

        vm.prank(EOA);
        REGISTRY.bind(SAFE); // and can now undo

        (bool ok, bytes32 subject) = RESOLVER.resolve(EOA);
        assertTrue(ok);
        assertEq(address(uint160(uint256(subject))), SAFE);
    }

    function test_removingFromAllowlistDeniesAgain() public {
        vm.prank(EOA);
        REGISTRY.bind(SAFE);
        (bool ok,) = RESOLVER.resolve(EOA);
        assertTrue(ok);

        address[] memory one = new address[](1);
        one[0] = EOA;
        vm.prank(GATE_OWNER);
        GATE.setAllowlisted(one, false);

        (ok,) = RESOLVER.resolve(EOA);
        assertFalse(ok, "revocation must work while no delegate is set");
    }
}
