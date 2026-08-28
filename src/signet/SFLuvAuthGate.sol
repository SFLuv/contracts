// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IAuthGate} from "./IAuthGate.sol";

/**
 * @title SFLuvAuthGate
 * @notice Who may open a Signet session, as a policy that can change without
 *         changing the resolver — and therefore without orphaning keys.
 *
 *         Deploy with `allowAll = false` and a staff allowlist for the trial;
 *         flip `allowAll` on for open rollout. The alternative — deploying the
 *         resolver with no gate — is a decision that cannot be revisited,
 *         because adding a gate later means a new resolver address and a
 *         re-enrolment for everyone already linked.
 *
 *         For rollout beyond the trial, `delegate` is the escape from curating
 *         a list by hand: point it at a policy contract that answers the
 *         membership question from chain state — e.g. "is this account's bound
 *         Safe running the SFLuv CommunityModule?", which distinguishes a wallet
 *         of this community from any other Safe on Celo without a trusted
 *         writer. Empty the allowlist and the delegate becomes the whole policy.
 *
 * @dev The gate is deliberately the *only* mutable piece of the auth path, and
 *      it is mutable in one direction that matters: it can deny. It never
 *      chooses a subject, so compromising it cannot move anyone's identity —
 *      the worst it does is admit addresses that should not have been admitted
 *      or lock out ones that should. Contrast the resolver and the bindings,
 *      where a change *would* move identities, and which are correspondingly
 *      immutable.
 *
 *      The delegate composes by OR and is therefore widening-only: it can admit
 *      accounts the allowlist does not, never veto ones it does. That is what
 *      keeps a swappable policy inside the same asymmetry as the rest of the
 *      gate — the owner could already admit everyone with `allowAll`, so
 *      delegating grants no power that was not already held. To narrow instead,
 *      empty the allowlist and leave the delegate as the only path in.
 *
 *      The delegate is called with a gas cap and its failures are swallowed, so
 *      a broken or hostile delegate cannot take the allowlist down with it. The
 *      resolver caps the call into this contract in turn, and the local checks
 *      run first — an allowlisted account never touches the delegate at all.
 */
contract SFLuvAuthGate is IAuthGate, Ownable2Step {
    /// @notice When true every address is admitted and the allowlist is ignored.
    bool public allowAll;

    mapping(address account => bool) public allowlisted;

    /// @notice Optional policy consulted when the local checks say no.
    ///         address(0) means the allowlist is the whole policy.
    IAuthGate public delegate;

    /// @dev Ceiling on the nested delegate read. Sized to sit inside the 100k
    ///      the resolver forwards to this contract, with room for a delegate
    ///      that itself reads a registry and then a Safe.
    uint256 private constant DELEGATE_GAS = 60_000;

    event AllowAllSet(bool allowAll);
    event AllowlistSet(address indexed account, bool allowed);
    event DelegateSet(address indexed delegate);

    constructor(address initialOwner, bool allowAll_, address[] memory initialAllowlist) Ownable(initialOwner) {
        allowAll = allowAll_;
        emit AllowAllSet(allowAll_);
        for (uint256 i = 0; i < initialAllowlist.length; ++i) {
            allowlisted[initialAllowlist[i]] = true;
            emit AllowlistSet(initialAllowlist[i], true);
        }
    }

    /// @inheritdoc IAuthGate
    function isAllowed(address account) external view returns (bool) {
        if (allowAll || allowlisted[account]) return true;

        IAuthGate d = delegate;
        if (address(d) == address(0)) return false;

        (bool success, bytes memory ret) =
            address(d).staticcall{gas: DELEGATE_GAS}(abi.encodeCall(IAuthGate.isAllowed, (account)));
        if (!success || ret.length != 32) return false;
        return abi.decode(ret, (bytes32)) != bytes32(0);
    }

    function setAllowAll(bool allowAll_) external onlyOwner {
        allowAll = allowAll_;
        emit AllowAllSet(allowAll_);
    }

    /// @notice Point at (or clear, with address(0)) the delegated policy.
    function setDelegate(IAuthGate delegate_) external onlyOwner {
        delegate = delegate_;
        emit DelegateSet(address(delegate_));
    }

    function setAllowlisted(address[] calldata accounts, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; ++i) {
            allowlisted[accounts[i]] = allowed;
            emit AllowlistSet(accounts[i], allowed);
        }
    }
}
