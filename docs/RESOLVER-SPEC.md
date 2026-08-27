# SFLUV auth resolver — spec

The contract that lets a Signet group answer "this address proved control — whose
account is it?" with **the user's Safe address**, so a Signet key is bound to the
wallet rather than to whichever IdP the user logged in with.

One contract, one view function, no per-user transactions.

---

## Hard constraints from the node

These are not style preferences; violating any of them fails auth at runtime.

| Constraint | Source | Consequence |
|---|---|---|
| `typeAndVersion()` MUST return exactly **`"SignetAuthResolver 1.0.0"`** | `node/resolver.go` `acceptedResolverVersions` | The accept-list is a protocol constant, not config. `"SFLuvAuthResolver 1.0.0"` is **rejected**. Nodes never disagree on acceptance, so a custom name needs a Signet release. |
| `resolve()` MUST NOT revert | `ISignetAuthResolver` | Return `(false, 0)` on every failure path. Any external call needs `try/catch`. |
| `resolve()` MUST NOT branch on `msg.sender` / `tx.origin` | R-2; the node pins `from = 0x0` | `MockAuthResolver.senderSensitive` exists specifically to prove nodes pin this. Sender-dependent logic makes nodes disagree and splits the vote. |
| MUST be a pure function of chain state at a block | R-3 | Nodes read at a client-pinned block + block hash. No randomness, no dependence on anything that varies within a block. |
| Resolver chain must be readable by **every** group member node | §6 | Deploying on Celo means OLL's four and SFLuv's two all need trusted Celo RPC. Auth fails closed if they lose it. |

The last one is an operational commitment, not a code change — worth confirming
with the node operators before deployment, not after.

---

## Variant A — derive-only (recommended for the trial)

Zero state. The Safe address is already a deterministic CREATE2 function of its
original owner, so the resolver just asks the Citizen Wallet factory.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISignetAuthResolver} from "./interfaces/ISignetAuthResolver.sol";

interface IAccountFactory {
    function getAddress(address owner, uint256 salt) external view returns (address);
}

/// @title SFLUV auth resolver (derive-only)
/// @notice Resolves an owner EOA to the Citizen Wallet Safe it deploys, so a
///         Signet session is namespaced by the wallet rather than by the login
///         provider. Holds no state: the mapping is CREATE2 arithmetic.
/// @dev Deployed IMMUTABLY. The resolver address is part of every key id
///      (`resolver:<addr>:<subject>`), and Signet has no mechanic to migrate
///      keys between resolver namespaces — so replacing this contract orphans
///      every key created under it. Do not put it behind a proxy either: that
///      would let the logic change without changing the namespace, defeating
///      the protection the namespacing exists to provide.
contract SignetAuthResolver is ISignetAuthResolver {
    IAccountFactory public immutable FACTORY;
    uint256         public immutable SALT;

    constructor(IAccountFactory factory, uint256 salt) {
        FACTORY = factory;
        SALT    = salt;
    }

    /// @inheritdoc ISignetAuthResolver
    function resolve(address account) external view returns (bool ok, bytes32 subject) {
        if (account == address(0)) return (false, bytes32(0));

        address safe;
        try FACTORY.getAddress(account, SALT) returns (address a) {
            safe = a;
        } catch {
            return (false, bytes32(0));
        }
        if (safe == address(0)) return (false, bytes32(0));

        // Require the Safe to exist. Enforces the "wallet created through Privy
        // first" invariant the enrolment flow already assumes, and stops a key
        // being minted against a wallet that was never deployed.
        if (safe.code.length == 0) return (false, bytes32(0));

        return (true, bytes32(uint256(uint160(safe))));
    }

    /// @inheritdoc ISignetAuthResolver
    /// @dev MUST match Signet's accept-list verbatim.
    function typeAndVersion() external pure returns (string memory) {
        return "SignetAuthResolver 1.0.0";
    }
}
```

Constructor args on Celo: `FACTORY = 0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185`,
`SALT = 0` (the primary wallet's `smart_index`).

**What it authorizes.** Anyone who controls an EOA whose derived Safe is
deployed. That is self-limiting — you only ever resolve to a Safe you already
deployed by owning that EOA — but it is open to the world, not to SFLUV users.
For the staff trial that's fine. If you want it closed, add an immutable
allowlist address and `try GATE.isAllowed(account)`; keep the *subject
derivation* immutable so a compromised gate can admit new addresses but can
never redirect an existing one.

**Its real limitation.** Authority comes from CREATE2 derivation, not from the
Safe's current owner set. Two consequences: a removed owner still resolves to
the Safe, and a *newly added* owner (the Signet key itself) does not. So this
variant cannot survive succession — the moment you `removeOwner(privyEOA)`, that
user can no longer authenticate, even though their wallet still works.

---

## Variant B — registry + `isOwner` (the production shape)

Needed as soon as owner sets change. A registry supplies a *candidate* Safe; the
Safe's own owner list is the authority.

```solidity
address safe = REGISTRY.safeFor(account);          // a hint, not a grant
if (safe == address(0) || safe.code.length == 0) return (false, bytes32(0));
try ISafe(safe).isOwner(account) returns (bool isOwner) {
    if (!isOwner) return (false, bytes32(0));
} catch { return (false, bytes32(0)); }
return (true, bytes32(uint256(uint160(safe))));
```

The security property worth noting: **the registry cannot grant identity.** It
can only nominate a Safe, and the on-chain `isOwner` check rejects any Safe the
account does not actually own. A compromised registry can deny service, or point
you at a different Safe you *also* own — it cannot steal someone else's.

That makes the registry safely upgradeable while the resolver stays immutable,
which is the split that keeps R-1's namespace protection intact.

It also makes the model coherent: any *current* owner authenticates as the
wallet. After succession the Signet key itself can sign the SIWE message and
resolve to the same subject — so identity follows the wallet, not the credential.

**Recommendation:** ship A for the trial, because it needs no registry and no
per-user writes. Move to B before the first `removeOwner`. Note the move costs a
re-enrolment for anyone already linked, since it means a new resolver address and
therefore a new key namespace — so decide deliberately rather than drifting into
A and discovering B later.

---

## Binding it to the group

Manager-only, timelocked, one time — not per user, and not on Celo.

```
SignetGroup.queueAuthResolver(chainId = 42220, resolver = <deployed>, requireCanonicalSubject = true)
   … wait removalDelay …
SignetGroup.executeAuthResolver()
```

`requireCanonicalSubject = true` matters: with it false, a `subject == 0` answer
falls back to namespacing by the raw EOA, which silently reintroduces exactly the
per-credential fragmentation this design exists to avoid.

Also needed on the Signet side, same batch of work:

- `siwe_domain` configured on the nodes, or the whole resolver path is disabled
  (`verifySIWE` bails with "siwe domain not configured").
- A rate-limit CIDR exemption for the Vercel proxy — all users share its egress
  IP against a 120/min `/v1/sign` limit.

---

## Open questions

1. **Which chain?** Celo puts the resolver next to the wallets but obliges every
   node operator to hold trusted Celo RPC. Hosting it on the Signet core chain
   avoids that but splits the read away from the Safe it describes.
2. **Multiple wallets.** `addWallet` creates further Safes at higher indices.
   Variant A pins `SALT = 0`; if a user's primary is not index 0, they resolve to
   the wrong Safe. Worth checking against `users.primary_wallet_address` before
   deploying.
3. **Open vs. gated.** Variant A authorizes any address with a deployed Safe.
   Acceptable for staff; decide before wider rollout.
