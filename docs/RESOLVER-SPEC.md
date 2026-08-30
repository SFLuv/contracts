# SFLUV auth resolver — spec

The contract that lets a Signet group answer "this address proved control —
whose account is it?" with **the user's Safe address**, so a Signet key is bound
to the wallet rather than to the credential that opened the session.

Implemented in `src/signet/`, tested in `test/SignetAuthResolver.t.sol`,
`test/SafeBindingRegistry.t.sol` and (against live Celo)
`test/SignetAuthResolverForkCelo.t.sol`.

This document is the design and the reasoning. To deploy and integrate it, work
from [RESOLVER-HANDOFF.md](./RESOLVER-HANDOFF.md) instead — node config, client
request shapes, error causes, and who does what in which order.

---

## What changed from the first draft

The first version of this spec proposed shipping a derive-only resolver
(`subject = factory.getAddress(account, 0)`) for the trial and moving to an
owner-checked one later. Four things were wrong with that, in descending order
of how much they cost:

**1. A fixed salt resolves real users to the wrong wallet.** Not a theoretical
edge — it is already false in production. Live SFLuv record:

| | |
|---|---|
| owner EOA | `0x0e314f1F33Ddf60D28D25d381aD871f2eF096640` |
| `getAddress(owner, 0)` | `0x72441d…6c63d` — the user's *Throwaway* wallet |
| `getAddress(owner, 1)` | `0x0f3dE0…8B498` — the user's **primary**, per `users.primary_wallet_address` |

Both are deployed, so the draft's `safe.code.length > 0` check cannot tell them
apart: the resolver would have silently namespaced that user's Signet keys under
a wallet they consider a throwaway. Open question 2 in the draft ("worth
checking against `users.primary_wallet_address`") is hereby answered — no, index
0 is not the primary, and no fixed index is right for everyone.
`test_fixedSaltDerivationPicksTheWrongWallet` pins this against mainnet Celo.

**2. Derivation is a bijection, so it converges nothing.** With factory and salt
fixed, `subject = f(account)` is one-to-one: two credentials produce two
subjects, exactly as if the session were namespaced by the raw address.
Namespacing by subject exists (design doc §5) precisely so a user's several
addresses converge to one identity; derive-only relabels the address and calls
it an identity. It also makes `requireCanonicalSubject = true` decorative,
since `ok = true` then implies `subject != 0` by construction.

**3. "Ship A now, move to B later" is self-defeating.** The resolver address is
half of every key id (`resolver:<addr>:<subject>`, R-1) and Signet has no
mechanic to migrate keys across resolver namespaces. So the migration the draft
recommended is a full re-enrolment for every linked user — the draft says as
much and recommends it anyway. There is exactly one deployment; it has to be the
shape that survives an owner change.

**4. The operational section named the wrong rate limit.** The resolver path
runs over `/v1/auth`, which is limited at the Caddy edge to **10 requests per
minute per client IP** (`rate_limit_auth_events`), not the 120/min the draft
cites for `/v1/sign`. The SDK posts auth to *every* node, and the limit is keyed
on `{remote_host}`, so a shared proxy egress IP caps **all SFLuv logins
together** at 10/min on each node it touches — and exemptions are per-operator
(`org_sfluv.yml`, `org_oll.yml`), so both orgs must add the CIDR or the ones who
did not become the bottleneck.

The corrected design keeps one thing from the draft unchanged: the resolver is
immutable and holds no policy.

---

## Hard constraints from the node

Violating any of these fails auth at runtime. Sources are in `signet-protocol`.

| Constraint | Source | Consequence |
|---|---|---|
| `typeAndVersion()` MUST return exactly **`"SignetAuthResolver 1.0.0"`** | `node/resolver.go` `acceptedResolverVersions` (the other entry is `MockAuthResolver 1.0.0`) | The accept-list is a protocol constant, not config. `"SFLuvAuthResolver 1.0.0"` is rejected by every node until a Signet release. The read is memoised per chain+address, so a wrong answer sticks until node restart. |
| `resolve()` MUST NOT revert | `ISignetAuthResolver` | Return `(false, 0)` on every failure path. |
| `resolve()` MUST NOT branch on `msg.sender` / `tx.origin` | R-2; the node pins `from = 0x0` | Sender-dependent logic makes nodes disagree and splits the vote. |
| MUST be a pure function of chain state at a block | R-3 | Nodes read at a client-pinned block; the block hash must be canonical in each node's own view. |
| SIWE `Chain ID` MUST equal the resolver's chain (**42220**) | `node/siwe.go` | Signing the message with the app's usual chain id fails auth. Three chains are in play — group home, resolver, SIWE — and the SIWE one must be the resolver's. |
| SIWE MUST carry `signet://session/<session_pub_hex>` in **Resources** | `node/siwe.go`, R-4 | Not the statement text. Exact match, lowercase hex. This binding is the only thing stopping a SIWE signature minted for another site from opening a Signet session. |
| SIWE MUST have an `Expiration Time` | `node/siwe.go` | It bounds the session; the node caps it at **24 h** regardless. |
| Client MUST pin `(block_number, block_hash)` within **30 blocks of head** | `node/chain.go` `maxResolverLag = 30` | Celo produces **1 s blocks** (measured), so this is a **~30-second window**. The client fetches the pin immediately before `/v1/auth` and retries on staleness; it therefore needs its own Celo RPC. The draft put the RPC requirement on node operators only. |
| Every group member node needs `chain_rpcs: {42220: …}` and a `siwe_domain` | `node/config.go`, `clientForChain` | Missing RPC fails closed for that node; an unset `siwe_domain` disables the whole resolver path. All six nodes (OLL's four, SFLuv's two) need trusted Celo RPC. |
| `/v1/auth` is rate limited to **10/min per IP** at the edge, on every node | `testnet/ansible/.../Caddyfile.j2` | See correction 4 above. In-node rate limiting (R-6) is still deferred; the edge is the only limit. |

One more that is not in the node's own list, and that the contract has to solve:

| Hazard | Why it matters |
|---|---|
| **Unbounded gas in a nested call** | Nodes' `eth_call` gas caps are provider-dependent. A Safe with a hostile fallback handler that burns gas would answer on a node with a generous cap and fail on a stingy one — the same split-vote failure R-2 closes for `msg.sender`. The resolver caps every external read at 100k gas, keeping the whole `resolve` under ~400k (asserted in `test_resolve_boundedGasAgainstBurner`). |

The Celo-RPC-for-everyone item is an operational commitment, not a code change.
It is accepted: a group's resolver chain is explicitly part of its on-chain
binding (`AuthResolver { chainId, resolver }`), so servicing this group means
holding trusted Celo RPC, by design rather than by accident. Confirm the
endpoints are in place before deployment, not after.

---

## Design: registry nominates, the Safe decides

Two contracts plus an optional gate. No derivation anywhere.

```
resolve(account):
    gate?  isAllowed(account)          — may deny, never chooses
    safe = REGISTRY.safeFor(account)   — a hint, not a grant
    require safe != 0 and safe.code.length > 0
    require ISafe(safe).isOwner(account)          — the authority
    return (true, bytes32(uint160(safe)))
```

**Why `isOwner` is the right authority.** It is the exact predicate the Citizen
Wallet stack already uses to authorize a user operation:
`UserOpHandler.validateUserOp` recovers the signer and returns
`OwnerManager(sender).isOwner(signer)`. So a Signet session granted this way
carries precisely the authority that already moves the wallet's funds — no new
privilege class, and no divergence between "who can spend" and "who is the
identity". (Note the corollary: the wallet's owner set is effectively 1-of-N for
execution regardless of `getThreshold()`, and the Signet identity inherits
that.)

**Why the registry cannot grant identity.** It only nominates. `isOwner` is
re-checked on every `resolve`, so the worst a wrong entry can do is deny service
or point an account at another Safe *that account also owns*. It can never hand
one person's subject to another.

That argument holds only while the entry names a Safe the account genuinely
owns — which is a property of who may *write* the entry, not of the read path.
The re-check defends against a lying registry; it cannot defend against a
binding that names a contract the attacker wrote, because the re-check then asks
the attacker. See the write-authorization bullet below. `test_resolve_registryCannotGrantIdentity`
holds this down.

The draft used that property to argue the registry could be upgradeable and
trusted. It does not need to be either:

- **Authorized by the account, and only the account.** `bind(safe)` binds
  `msg.sender`; `bindWithSignature` accepts a relayed write carrying the
  account's EIP-712 signature, so enrolment can be gasless without introducing
  a writer. No owner, no roles, no admin — nothing to compromise, and no third
  party can write a binding for an address it does not control.

  The first deployment also accepted `msg.sender == safe`, reasoning that a
  wallet vouching for its own owner is self-authorizing. **That was wrong, and
  it was exploitable**: the caller chooses which contract plays the part of the
  Safe, and `isOwner` is then answered by that same contract. Anyone could pin
  any unbound EOA to an address of their choosing, permanently. The lesson is
  narrow and worth keeping: asking the nominated Safe to vouch for the binding
  is circular, because the nomination is the thing under attack.
- **Validated on write** (`isOwner` must already hold) *and* on read.
- **Re-bindable by the account alone.** Re-pointing moves the namespace the
  account's future sessions land in, so it is a deliberate identity move rather
  than a correction — but forbidding it outright made a mistaken binding
  permanent in a contract that cannot be upgraded. Rebinding grants no reach:
  landing on a Safe still requires already being one of its owners.

Losing a credential is handled by the owner set, not by rewriting history: add
the new EOA as a Safe owner, bind it to the **same** Safe, and it resolves to the
same subject; remove the old owner and it stops authenticating. Identity follows
the wallet. `test_resolve_survivesOwnerRotation`.

### What this costs

One `bind` transaction per credential, before its first Signet login. The
natural path is a sponsored user operation from the Safe itself through the
CommunityModule — the same rail the wallet already uses, so it is invisible to
the user and costs them no gas. SFLuv cannot batch-prefill bindings from the
database, because binding requires the account or the Safe to act; that is the
price of having no trusted writer, and it is the right trade.

### The gate — and why this resolver needs one at all

The ACE/CCID adapter the interface was designed around defers to an **authority**:
a CCID is something a process granted you, so "whoever the registry says" is
exactly the intended population, and `resolve()` fusing authorize+resolve into one
call (design doc §2) is right because one authority answers both halves.

SFLuv has no such authority underneath. `AccountFactory.createAccount` is
unpermissioned — anyone can deploy a Citizen Wallet Safe for any owner, for the
price of the gas. So the *resolve* half is meaningful ("which wallet is this
address?") while the *authorize* half has nothing to defer to: a wallet's
existence is a statement about control, not about membership. Deferring to it
authorizes the world. And this resolver is a **sibling** of the group's other
auth schemes, not an extra check on top of them — `handleAuth` selects a branch
by which fields the request carries, `HasAuthPolicy` is an OR, and the resolver
branch establishes a session with no app-held credential anywhere in it. Once the
binding is live, the gate is the group's only admission control on that path.

`SignetAuthResolver` therefore takes an immutable `GATE`. `address(0)` means
open: anyone who owns any Safe on Celo — the registry checks `isOwner`, not
provenance — could bind it and open a session. A gate can only deny, and never
influences which Safe an account resolves to, so a compromised gate can admit or
lock out but can never move an identity. That asymmetry is what lets the gate
stay mutable while everything that determines a subject stays immutable.

**Deploy with a gate even if it starts wide open.** Adding one later means a new
resolver address and a re-enrolment for everyone linked.

**And don't leave the allowlist as the only policy it can ever express.**
`SFLuvAuthGate` carries an owner-settable `delegate`, consulted by OR when the
local checks say no, so admission can later be answered from chain state instead
of a curated list. The delegate to grow into: **the CommunityModule**. Every
wallet the factory deploys has module `0x7079253c…F403B6` enabled, and the
pairing is structural rather than incidental — `AccountFactory` takes
`_communityModule` in its constructor and is itself deployed by CREATE2 under a
fixed salt, so the factory address and the module are one-to-one. `isModuleEnabled`
therefore reads as "this wallet belongs to this Citizen Wallet community", which
is the membership predicate the chain can actually answer. It narrows the door
from every Safe on Celo to the community's wallets with no curation and no
trusted writer, and `test_communityModuleDelegateAdmitsRealWalletOnly` runs it
end to end against live Celo state, inside the gas budget.

Two properties keep the delegate inside the same asymmetry as the rest of the
gate: it composes by OR, so it can only widen — the owner could already admit
everyone with `allowAll`, so delegating grants no power that was not already
held — and it is called under a gas cap with its failures swallowed, so a broken
delegate cannot take the allowlist down with it. To narrow rather than widen,
empty the allowlist and leave the delegate as the only way in.

*Unconfirmed:* that this module is exclusive to SFLuv. The factory address is a
pure function of the module, so another Citizen Wallet community pointing at the
same factory would be indistinguishable. Worth asking Citizen Wallet before the
delegate carries the policy on its own.

---

## Deployment

Summarised here; the step-by-step, with verification commands and the node-side
prerequisites, is in [RESOLVER-HANDOFF.md](./RESOLVER-HANDOFF.md).

```bash
EXPECTED_CHAIN_ID=42220 GATE_OWNER=<sfluv multisig> GATE_ALLOW_ALL=false \
forge script script/DeploySignetResolver.s.sol:DeploySignetResolver \
  --rpc-url https://forno.celo.org --private-key $PRIVATE_KEY --broadcast
```

Then bind it to the group. Manager-only, timelocked, one time — on the group's
chain (**Ethereum mainnet**, group `0x86fe28144034fdaf86d3c964296dd33e4b94ac59`),
not on Celo:

```
SignetGroup.queueAuthResolver(chainId = 42220, resolver = <deployed>, requireCanonicalSubject = true)
   … wait removalDelay (currently 600 s on the live group) …
SignetGroup.executeAuthResolver()
```

`requireCanonicalSubject = true` matters: with it false, a `subject == 0` answer
falls back to namespacing by the raw EOA — the per-credential fragmentation this
design exists to avoid. This resolver never returns `ok=true` with a zero
subject, so the flag is pure defence in depth; set it anyway.

Also needed on the Signet side, same batch of work:

- `siwe_domain` configured on all six nodes, or the resolver path is disabled
  outright (`verifySIWE` bails with "siwe domain not configured").
- `chain_rpcs: {42220: <trusted Celo endpoint>}` on all six nodes.
- A rate-limit CIDR exemption for the proxy egress in **both** `org_sfluv.yml`
  and `org_oll.yml` — `/v1/auth`, 10/min/IP, applied at every node the SDK posts
  to.
- Client-side: fetch `(block_number, block_hash)` from Celo immediately before
  each `/v1/auth`, and retry on "too stale" — the window is ~30 s.

---

## Open questions

1. ~~**Which chain?**~~ **Closed: Celo.** The alternative is worth recording,
   because it is not obviously worse on paper. Hosting the resolver on the group's
   own chain (Ethereum mainnet) costs the operators nothing — the home chain is
   auto-registered for resolver reads from `eth_rpc`, so no `chain_rpcs` entry is
   needed — and mainnet's 12 s blocks widen the R-3 pin window from ~30 s to ~6
   minutes.

   It loses the design, though. A mainnet contract cannot call the Safe, so
   `isOwner` stops being available as the authority and every property that
   hangs off it has to be rebuilt from signatures: claims proving deploy-time
   ownership by CREATE2 derivation, an explicit consent graph for convergence and
   succession, and a guardian for revocation — all of it frozen at write time,
   because mainnet only ever holds a snapshot of Celo. Live owner state is worth
   more than a wider pin window and a config line, so: Celo, and the operators
   carry the RPC.
2. ~~**Open or gated at launch?**~~ **Closed: allowlist for initial rollout,**
   gating the integration to staff. The path out of hand-curation is the
   delegate, not a redeploy — set it to a CommunityModule policy when the trial
   opens up, and empty the allowlist.
3. **Revocation SLA.** Authorization binds at session creation, so removing a
   Safe owner does not end that owner's live session — it lasts until expiry,
   capped at 24 h (R-5). If SFLuv needs faster, the knob is session TTL, not the
   resolver.
4. **Convergence is enabled, not created.** Two Privy logins converge only if the
   second EOA is actually added as an owner of the first's Safe. Today they are
   separate wallets — see the two records sharing EOA `0x9e25fe…` under different
   Privy DIDs. Deciding who adds that owner, and when, is an app-side flow this
   contract set assumes but does not perform.
