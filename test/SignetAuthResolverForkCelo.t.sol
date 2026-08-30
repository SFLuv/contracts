// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IAuthGate} from "../src/signet/IAuthGate.sol";
import {ISafe} from "../src/signet/ISafe.sol";
import {SafeBindingRegistry} from "../src/signet/SafeBindingRegistry.sol";
import {SFLuvAuthGate} from "../src/signet/SFLuvAuthGate.sol";
import {SignetAuthResolver} from "../src/signet/SignetAuthResolver.sol";

import {MockSafe, ModuleMembershipGate} from "./mocks/SignetMocks.sol";

interface IAccountFactory {
    function getAddress(address owner, uint256 salt) external view returns (address);
}

/**
 * @notice Fork checks against the live Citizen Wallet deployment on Celo.
 *
 *         Set CELO_RPC_URL to run; the suite no-ops without it so the default
 *         `forge test` stays offline.
 *
 *         The first test is the one that decided the design: it shows a real
 *         production user whose primary wallet is at smart_index 1, so any
 *         resolver that derives the Safe from a fixed salt resolves that user
 *         to the wrong wallet — silently, because both wallets are deployed and
 *         a code-length check cannot tell them apart.
 */
contract SignetAuthResolverForkCeloTest is Test {
    address internal constant ACCOUNT_FACTORY = 0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185;

    // Live SFLuv records. This account holds two deployed Citizen Wallet Safes
    // and its primary is the index-1 one.
    address internal constant OWNER_EOA = 0x0e314f1F33Ddf60D28D25d381aD871f2eF096640;
    address internal constant PRIMARY_SAFE = 0x0f3dE0f4ce42C059165cf60d7361d8C5AE38B498; // smart_index 1
    address internal constant SECONDARY_SAFE = 0x72441d9C8fbf917495f69798757e3D7A18a6c63d; // smart_index 0

    // The CommunityModule paired 1:1 with the account factory above — enabled on
    // every wallet the factory deploys, and the only on-chain signal that
    // distinguishes a wallet of this community from any other Safe on Celo.
    address internal constant COMMUNITY_MODULE = 0x7079253c0358eF9Fd87E16488299Ef6e06F403B6;

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("CELO_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    function test_fixedSaltDerivationPicksTheWrongWallet() public view {
        if (!forked) return;

        IAccountFactory factory = IAccountFactory(ACCOUNT_FACTORY);
        assertEq(factory.getAddress(OWNER_EOA, 0), SECONDARY_SAFE, "index 0 is not this user's primary");
        assertEq(factory.getAddress(OWNER_EOA, 1), PRIMARY_SAFE);

        // Both are deployed, so "require the Safe to exist" does not
        // disambiguate them.
        assertGt(SECONDARY_SAFE.code.length, 0);
        assertGt(PRIMARY_SAFE.code.length, 0);

        assertTrue(ISafe(PRIMARY_SAFE).isOwner(OWNER_EOA));
        assertTrue(ISafe(SECONDARY_SAFE).isOwner(OWNER_EOA));
    }

    function test_resolvesRealWalletAfterBinding() public {
        if (!forked) return;

        SafeBindingRegistry registry = new SafeBindingRegistry();
        SignetAuthResolver resolver = new SignetAuthResolver(registry, IAuthGate(address(0)));

        (bool ok,) = resolver.resolve(OWNER_EOA);
        assertFalse(ok, "unbound account must not authenticate");

        // The production path: the owner binds itself to its wallet. Only the
        // account can authorise this — a Safe vouching for its own owner is
        // circular, and was the hole in the first version of the registry.
        vm.prank(OWNER_EOA);
        registry.bind(PRIMARY_SAFE);

        bytes32 subject;
        (ok, subject) = resolver.resolve(OWNER_EOA);
        assertTrue(ok);
        assertEq(subject, bytes32(uint256(uint160(PRIMARY_SAFE))));
    }

    /// The rollout policy, end to end against live state: admission answered by
    /// "does this account's bound Safe run the community module?" — no list.
    function test_communityModuleDelegateAdmitsRealWalletOnly() public {
        if (!forked) return;

        SafeBindingRegistry registry = new SafeBindingRegistry();
        SFLuvAuthGate gate = new SFLuvAuthGate(address(this), false, new address[](0));
        SignetAuthResolver resolver = new SignetAuthResolver(registry, gate);
        gate.setDelegate(new ModuleMembershipGate(registry, COMMUNITY_MODULE));

        vm.prank(OWNER_EOA);
        registry.bind(PRIMARY_SAFE);

        uint256 before = gasleft();
        (bool ok, bytes32 subject) = resolver.resolve(OWNER_EOA);
        uint256 used = before - gasleft();

        assertTrue(ok, "a real community wallet must pass the module policy");
        assertEq(subject, bytes32(uint256(uint160(PRIMARY_SAFE))));
        // resolver -> gate -> delegate -> registry + a real Safe 1.4.1 proxy,
        // which delegatecalls its singleton to answer isModuleEnabled.
        assertLt(used, 100_000, "the full delegated chain fits the node's budget");

        // A Safe that is not part of this community is refused, which is the
        // whole point: owning *a* Safe on Celo is not membership.
        address outsider = makeAddr("outsider");
        MockSafe foreignSafe = new MockSafe(outsider);
        vm.prank(outsider);
        registry.bind(address(foreignSafe));

        (bool outsiderOk,) = resolver.resolve(outsider);
        assertFalse(outsiderOk, "a Safe without the community module is not a member");
    }
}
