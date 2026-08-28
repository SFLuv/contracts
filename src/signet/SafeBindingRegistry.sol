// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ISafe} from "./ISafe.sol";
import {ISafeBindingRegistry} from "./ISafeBindingRegistry.sol";

/**
 * @title SafeBindingRegistry
 * @notice Records which Safe an address is a member of, so SignetAuthResolver
 *         can namespace a Signet session by the wallet instead of by the
 *         credential that opened it.
 *
 *         The registry is a *hint*, never a grant. It nominates a Safe; the
 *         Safe's own `isOwner` is the authority, re-checked by the resolver on
 *         every `resolve`. Everything below is about making that hint honest
 *         and stable, not about making it trusted.
 *
 * @dev Three properties, each load-bearing:
 *
 *      1. **Self-authorizing.** A binding may only be created by the account
 *         itself or by the Safe it names. There is no owner, no role, no
 *         admin — nobody can bind on someone else's behalf, so there is no
 *         privileged writer to compromise and no front-running grief where a
 *         third party pins your account to a Safe you own but did not choose.
 *
 *      2. **Validated at write time.** `isOwner(account)` must already hold, so
 *         a binding can never nominate a Safe the account has no claim on. This
 *         is belt-and-braces: the resolver checks it again at read time.
 *
 *      3. **Write-once.** A bound account can never be re-pointed. A Signet key
 *         id embeds the subject (`resolver:<addr>:<subject>`), so moving a
 *         binding would move a live key namespace — the exact hijack that
 *         signet-protocol's R-1 namespacing exists to prevent. Immutability
 *         here is what lets the registry stay open and unowned.
 *
 *      Losing a wallet is therefore a new identity, deliberately: bind the new
 *      EOA to the *same* Safe and the subject is unchanged; bind it to a
 *      different Safe and it is a different principal, which is the truth.
 *
 *      Multiple accounts may bind to the same Safe. That is the point — it is
 *      how two logins (two Privy EOAs, both added as owners) converge on one
 *      subject.
 */
contract SafeBindingRegistry is ISafeBindingRegistry {
    mapping(address account => address safe) private _safeOf;

    event SafeBound(address indexed account, address indexed safe, address indexed boundBy);

    error ZeroAddress();
    /// @dev Caller is neither the account nor the Safe named in the binding.
    error NotSelfAuthorized(address caller);
    error AlreadyBound(address account, address safe);
    error NotAnOwner(address account, address safe);

    /**
     * @notice Bind `account` to `safe`, permanently.
     * @dev Callable by `account` (an EOA signing directly) or by `safe` itself
     *      (the normal path: a sponsored user operation through the Citizen
     *      Wallet CommunityModule, which is already how these wallets act).
     *      Reverting here is fine and intended — this is the write path. Only
     *      `SignetAuthResolver.resolve` carries the never-revert obligation.
     */
    function bind(address account, address safe) external {
        if (account == address(0) || safe == address(0)) revert ZeroAddress();
        if (msg.sender != account && msg.sender != safe) revert NotSelfAuthorized(msg.sender);

        address existing = _safeOf[account];
        if (existing != address(0)) revert AlreadyBound(account, existing);

        if (!ISafe(safe).isOwner(account)) revert NotAnOwner(account, safe);

        _safeOf[account] = safe;
        emit SafeBound(account, safe, msg.sender);
    }

    /// @inheritdoc ISafeBindingRegistry
    function safeFor(address account) external view returns (address safe) {
        return _safeOf[account];
    }
}
