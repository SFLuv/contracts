# SFLUV Signet auth resolver — deployment & integration handoff

Everything needed to get the on-chain auth resolver deployed and wired up, for
three audiences at once. Design rationale lives in
[RESOLVER-SPEC.md](./RESOLVER-SPEC.md); this document is the work.

**What it does.** A user signs a SIWE message with the EOA behind their SFLuv
wallet. Every Signet node independently reads a contract on Celo that answers
"which Safe does this address own?", and namespaces the session under that Safe
address. Identity follows the wallet, not the login provider.

**Contracts** (`src/signet/`, all on Celo, chain 42220):

| Contract | Mutable? | Role |
|---|---|---|
| `SignetAuthResolver` | **immutable, ownerless** | What Signet calls. Reads the registry, verifies with the Safe, returns the subject. |
| `SafeBindingRegistry` | **immutable**, permissionless, write-once | Records account → Safe. Self-authorizing; no admin. |
| `SFLuvAuthGate` | mutable, owned by SFLuv | Admission policy. Can only deny. |

---

## Who does what

| # | Work | Owner | Blocks |
|---|---|---|---|
| A | ~~Deploy the three contracts on Celo~~ — **done**; staff allowlist still to be set | SFLuv | D |
| B | Node config on all six nodes | OLL (4 nodes) + SFLuv (2 nodes) | D |
| C | Client support for the `onchain_resolver` scheme — **does not exist in the SDK today** | OLL (SDK) or SFLuv (app) | E |
| D | Bind the resolver to the group (manager, timelocked) | SFLuv (group manager) | E |
| E | App enrolment + login flow | SFLuv | — |

A, B and C are independent and can run in parallel. **D must come after B**: the
moment the binding executes, any node without Celo RPC starts failing auth.

---

## A. Deploy the contracts (SFLuv, Celo) — ✅ DONE 2026-08-30

Deployed at Celo block **76208199** by an ops key that retains no authority;
addresses are in [Reference](#addresses). The gate is owned by the group manager
`0x762F…403B` and is **closed** (`allowAll=false`, empty allowlist, no
delegate), so `resolve()` returns `(false, 0x0)` for everyone. Nothing is live
until step D. Kept here for the record and for re-deploying to a test network:

```bash
EXPECTED_CHAIN_ID=42220 \
GATE_OWNER=0x762F96819a7705448843E96D63D638Ec2f39403B \
GATE_ALLOW_ALL=false \
forge script script/DeploySignetResolver.s.sol:DeploySignetResolver \
  --rpc-url https://forno.celo.org --private-key $PRIVATE_KEY --broadcast
```

**Remaining in this workstream: allowlist the staff.** `GATE_ALLOW_ALL=false` is
the decision recorded in the spec — the trial is gated to staff — and until this
runs, nobody can authenticate. One batch, signed by the group manager key:

```bash
cast send 0x78B405B629e7c27F81d7dF3dCEcC097f58B47053 \
  "setAllowlisted(address[],bool)" "[<eoa1>,<eoa2>,…]" true \
  --rpc-url https://forno.celo.org --private-key $GATE_OWNER_KEY
```

Allowlist the **owner EOAs** (the Privy addresses that sign SIWE), not the
Safes. The manager key has never transacted on Celo — fund it with ~1 CELO
first; a batch costs roughly 0.03 CELO at current gas.

**Verification (run and recorded at deploy).** The first check is the one that
fails auth network-wide if it is wrong, because Signet's accept-list is a
protocol constant:

```bash
R=https://forno.celo.org
RES=0x0571e773F921EF683c80a5bCFAEc7D06Edae6ce3
cast call $RES "typeAndVersion()(string)" --rpc-url $R
# → "SignetAuthResolver 1.0.0"   (exactly; anything else is rejected by every node)
cast call $RES "REGISTRY()(address)"      --rpc-url $R   # → 0xAa42…CD85
cast call $RES "GATE()(address)"          --rpc-url $R   # → 0x78B4…7053
cast call $RES "resolve(address)(bool,bytes32)" <unbound eoa> --rpc-url $R
# → false, 0x0…0   (nothing resolves until allowlisted *and* bound — expected)
```

Identify contracts by their **getters, not by a pasted deploy log** — `forge`'s
printed summary transposed the registry and gate names on this deploy, though
its `run-latest.json` was correct. The gate answers `owner()`; the registry
answers `safeFor()`.

---

## B. Node configuration (all six nodes)

Both settings are currently unset fleet-wide, which leaves the scheme disabled
everywhere. In `group_vars/`:

```yaml
# The exact ERC-4361 domain clients sign against. NODE-LEVEL, not per-group:
# one value per node, shared by every group it serves. Empty = the whole
# onchain_resolver path is rejected before any chain read.
siwe_domain: "<the SFLuv app's domain>"

# Celo RPC for the resolver read. Must be trusted — this read gates session
# creation. Six nodes behind one public endpoint is a single point of both
# failure and lie.
chain_rpcs:
  42220: "https://<trusted celo endpoint>"
```

`siwe_domain` being node-level rather than per-group is a **coordination item,
not a config line**: OLL's four nodes can serve exactly one SIWE domain across
all of their groups. Confirm before setting it.

Both flow through `roles/signetd/templates/config.yaml.j2`, which carries
`notify: restart signetd` — so applying this is a **rolling restart of all six
nodes**, dropping in-flight keygen/sign and in-memory sessions. Stage it, and
keep it out of the same window as step D.

Also add the rate-limit exemption for the app's egress. `/v1/auth` is limited at
the Caddy edge to **10 events/min keyed on `{remote_host}`**, the SDK posts auth
to *every* node, and exemptions are per-operator — so the CIDR goes in **both**
`org_sfluv.yml` and `org_oll.yml`:

```yaml
rate_limit_exempt_cidrs:
  - <app egress>/32
```

> **Check first that the app has a stable egress IP.** Vercel functions do not by
> default — dedicated egress is an Enterprise feature. If there is no stable IP,
> a CIDR exemption cannot be expressed and the lever is raising
> `rate_limit_auth_events` instead.

**Partial rollout degrades quietly.** A node without Celo RPC errors in
`clientForChain`, never caches the session, and simply cannot participate. With
6 members at threshold 3, **up to three nodes can lack it before auth breaks
entirely** — so a half-finished rollout looks fine until the fourth node.

**There is no remote readiness check.** `/v1/info` returns peer id, eth address,
node type and build identity — not configured chains, not whether `siwe_domain`
is set. Until that changes you are trusting six operators' word, or discovering
the gap from an auth error. See *Gaps to raise*.

---

## C. Client support for `onchain_resolver` (does not exist yet)

**`signet-sdk` has no SIWE or resolver support** — no file under `src/` mentions
it. `bootstrap.ts` covers OAuth/ZK, `authkey-session.ts` covers certificates,
`delegate.ts` covers delegation. The resolver path has to be added to the SDK or
hand-rolled in the app. This is the largest remaining piece of work and it is
not on the critical path for A, B or D — start it now.

### The SIWE message

Standard ERC-4361, with four fields the node checks and will reject on:

| Field | Value | Node check |
|---|---|---|
| `domain` | must equal the nodes' `siwe_domain` | exact |
| `Chain ID` | **42220** — the *resolver's* chain, not the app's | exact |
| `Resources` | exactly one entry: `signet://session/<sessionPubHex>` | case-insensitive exact match |
| `Expiration Time` | required; bounds the session, capped at **24 h** | required, must be future |
| `Nonce` | required for the message to parse (ERC-4361) | *not* replay-checked — see Gaps |

`<sessionPubHex>` is the 33-byte compressed secp256k1 session public key as
lowercase hex **with no `0x` prefix**, e.g.
`signet://session/02a1b2c3…`. It must be in `Resources` — the node will not read
it out of the statement text. This binding is the only thing stopping a SIWE
signature minted for another site from opening a Signet session, so it is
checked strictly.

### The block pin

The request commits to a recent Celo block, and every node re-reads `resolve()`
at exactly that block so they all see identical state.

```
head - 30 ≤ block_number ≤ head        (maxResolverLag = 30, per node's own head)
block_hash must be canonical at that height in each node's own view
```

Celo produces **1-second blocks**, so this is roughly a **30-second window**.
Fetch `(number, hash)` immediately before the request and retry on a staleness
error rather than caching it. **The client needs its own Celo RPC** for this.

### One node, not all of them

Nodes are symmetric. `/v1/auth` broadcasts a `msgAuth` coord message to the
participants, and each one independently re-runs the SIWE recovery and the
resolver read at the pinned block rather than trusting the initiator's verdict
(`handlers.go`, `coord.go`). All four auth schemes work this way. Because every
node reads at the same pinned block, no two of them can reach *conflicting*
verdicts.

What can differ is whether a node reaches a verdict at all. A participant that
cannot do the resolver read NACKs and never caches the session — no
`chain_rpcs` entry, an RPC lagging behind the pin, a hash it does not see as
canonical, or its own head far enough ahead that the 30-block window has
closed. So propagation can be partial, and it is silent: the client already has
its `200` from the initiator.

The broadcast is **asynchronous**, so `/v1/auth` returns before the
participants have cached the session. Authenticating and then immediately
signing against a *different* node can lose that race. Either retry the sign
once on a 401, or call the other nodes as a barrier.

A 401 from a participant has three causes that look identical from outside, and
they need different fixes:

| Cause | Fix |
|---|---|
| It has not processed the broadcast yet | retry the sign |
| It was unreachable when the broadcast went out | **re-auth** — there is no backfill; a participant that missed `msgAuth` never learns the session, it just NACKs (`coord.go`), and `handlers.go` says the recovery is for the client to re-auth |
| It cannot reach Celo at all | neither — that node is out until step B is fixed on it |

Note the protocol harness calls every node, and says why: a cheap barrier that
keeps propagation noise out of its measurements, not a requirement. The SDK's
`bootstrap.ts` fans out too, and its comment explains the same thing — but its
opening line reads as a requirement, which is the natural way to conclude
fan-out is needed. It isn't.

This path has a wider window than the other schemes: each participant makes its
own `eth_call` at the pinned block, so propagation is bounded by every node's
RPC latency to Celo.

### The request

`POST /v1/auth` **to one node**:

```jsonc
{
  "group_id":       "0x86fe28144034fdaf86d3c964296dd33e4b94ac59",
  "session_pub":    "02…",        // 33-byte compressed secp256k1, hex
  "siwe_message":   "<full ERC-4361 message text>",
  "siwe_signature": "0x…",        // 65-byte personal_sign over the message
  "block_number":   12345678,
  "block_hash":     "0x…"         // 32 bytes
}
```

Response:

```jsonc
{ "status": "ok", "identity": "<subject hex — the Safe address>", "expires_at": 1234567890 }
```

From there the session behaves like any other: `session_pub` plus a request
signature, per the existing SDK paths.

### Error → cause

Every one of these comes back as `401 resolver auth failed: <msg>`.

| Message | Cause |
|---|---|
| `siwe domain not configured; onchain_resolver disabled` | node's `siwe_domain` unset (step B) |
| `group has no auth resolver configured` | binding not executed yet, or not polled (step D) |
| `chain client unavailable` / `no RPC configured for chain 42220` | node missing `chain_rpcs` (step B) |
| `unsupported resolver version "…"` | resolver's `typeAndVersion` outside the accept-list |
| `siwe chain id N != resolver chain id 42220` | signed with the app's chain instead of Celo's |
| `siwe message missing session resource signet://session/…` | resource absent, malformed, or in the statement instead |
| `siwe message missing expiration time` | no `Expiration Time` |
| `verify siwe: …` | bad signature, wrong domain, or expired |
| `pinned block N too stale (head M, max lag 30)` | pin older than ~30 s — refetch and retry |
| `pinned block N ahead of head M` | client's RPC ahead of the node's |
| `pinned block hash mismatch at N` | reorg, or hash from a different chain/height |
| `resolver did not authorize address 0x…` | not bound, no longer a Safe owner, or gate denied |

---

## D. Bind the resolver to the group (after B)

Group manager only, on the group's chain (**Ethereum mainnet**), group
`0x86fe28144034fdaf86d3c964296dd33e4b94ac59`:

```bash
GROUP=0x86fe28144034fdaf86d3c964296dd33e4b94ac59
RESOLVER=0x0571e773F921EF683c80a5bCFAEc7D06Edae6ce3
cast send $GROUP "queueAuthResolver(uint64,address,bool)" 42220 $RESOLVER true --rpc-url $ETH_RPC …
# wait removalDelay — 600 s on the live group
cast send $GROUP "executeAuthResolver()" --rpc-url $ETH_RPC …
```

`requireCanonicalSubject = true`: with it false, a zero subject would fall back
to namespacing by the raw EOA, reintroducing the per-credential fragmentation
this design exists to remove. This resolver never returns a zero subject on
success, so it is defence in depth — set it anyway.

Check the queue and the result:

```bash
cast call $GROUP "getPendingAuthResolver()((uint256,(uint64,address,bool),address))" --rpc-url $ETH_RPC
cast call $GROUP "getAuthResolver()((uint64,address,bool))"                          --rpc-url $ETH_RPC
```

No restart is needed for the binding itself: `AuthResolverSet` is a watched
topic and lands within one `chain_poll_secs` tick (60 s default).

**Backing out.** `cancelAuthResolver()` withdraws a queued change, but only the
original initiator may call it. After execution, clearing is another timelocked
round trip: `queueAuthResolver(0, address(0), false)`, wait, execute. Keys
created under the resolver stay addressable only under its namespace, so
unbinding strands them — treat this as a one-way door, not a rollback.

---

## E. App integration (SFLuv)

### One-time: bind the wallet

Nothing resolves until an account is bound. `bind` is callable **only by the
account itself or by the Safe it names** — there is no admin path, so SFLuv
cannot prefill bindings from the database. The natural route is a sponsored user
operation from the Safe through the CommunityModule, the same rail the wallet
already uses, which makes it invisible and gasless for the user:

```bash
cast calldata "bind(address,address)" <ownerEOA> <safe>
# → execTransactionFromModule(registry, 0, <calldata>, 0) via the CommunityModule
```

Requirements at bind time: `isOwner(account)` must already hold, and neither
address may be zero. It is **write-once** — a bound account can never be
re-pointed, because moving a binding would move a live key namespace. Bind the
wallet the user considers primary; `users.smart_index` identifies which one.

### Every login

1. Generate a session keypair; take the 33-byte compressed pubkey.
2. Build the SIWE message (§C) and have the Privy EOA sign it.
3. Fetch a fresh Celo `(block_number, block_hash)`.
4. `POST /v1/auth` to one node.
5. On `too stale`, refetch the block and retry — do not cache the pin.

### What the app should expect

- **Revocation is not instant.** Authorization binds at session creation, so
  removing a Safe owner does not end that owner's live session; it lasts until
  expiry, capped at 24 h. If that is too slow, the lever is session TTL.
- **Two credentials converge only if both are Safe owners.** Adding a second
  Privy EOA as an owner and binding it to the same Safe gives the same subject.
  Without that owner change they remain two separate wallets and two identities.

---

## Gaps to raise with the Signet side

Found while implementing; none blocks deployment, all three are worth filing.

1. **SIWE nonce is not replay-checked on the resolver path.** `verifySIWE`
   returns the nonce with the comment that "the caller routes result.Nonce
   through the session nonce cache", and `validateResolverProof` does not.
   Bounded in impact — the message binds `session_pub`, so a replay re-opens the
   *same* session, within its expiry and the ~30 s pin window, and is useless
   without the session private key — but R-4's replay story is not fully
   implemented as written.
2. **No readiness signal.** `/v1/info` cannot tell you whether a node has
   `siwe_domain` set or Celo RPC configured. Design doc §6 already argues nodes
   should advertise network capability; adding `chains` and a `siwe_domain_set`
   flag would turn the step-B pre-flight into a curl.
3. **R-6 in-node rate limiting is still deferred.** The edge (Caddy) is the only
   limiter, and the `TODO(R-6/M2)` sits directly above the branch that makes a
   cross-chain `eth_call` per request.

---

## Reference

### Addresses

| | Chain | Address |
|---|---|---|
| Signet group | Ethereum mainnet | `0x86fe28144034fdaf86d3c964296dd33e4b94ac59` |
| Citizen Wallet account factory | Celo | `0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185` |
| CommunityModule | Celo | `0x7079253c0358eF9Fd87E16488299Ef6e06F403B6` |
| `SignetAuthResolver` | Celo | `0x0571e773F921EF683c80a5bCFAEc7D06Edae6ce3` |
| `SafeBindingRegistry` | Celo | `0xAa42790F463DDCBfDC808275589222A61CeCCD85` |
| `SFLuvAuthGate` | Celo | `0x78B405B629e7c27F81d7dF3dCEcC097f58B47053` |
| Gate owner / group manager | Celo + mainnet | `0x762F96819a7705448843E96D63D638Ec2f39403B` |

Deployed 2026-08-30 at Celo block **76208199**, from `0xcD44c7b9AeA6b90375a3888C02F70618d3387379` at nonces 0-2. The resolver address is half of
every Signet key id and can never change without orphaning keys.

> **`forge`'s printed terminal summary transposed the registry and gate names.**
> Only that one block was wrong. The script, `broadcast/…/run-latest.json`, the
> creation nonces and the deployed getters all agree with the table above:
> nonce 0 → registry `0xAa42…CD85` (answers `safeFor()`), nonce 1 → gate
> `0x78B4…7053` (answers `owner()`), nonce 2 → resolver. Because the broadcast
> JSON is correct, everything that consumes it is correct too — including
> `forge verify-contract`, so block-explorer verification labels them properly.
> Identify these contracts by their getters, not by a pasted deploy log.

Deployment state at hand-off — closed and inert, nothing resolves yet:

```
typeAndVersion()  "SignetAuthResolver 1.0.0"   exact accept-list match
REGISTRY()        0xAa42790F463DDCBfDC808275589222A61CeCCD85
GATE()            0x78B405B629e7c27F81d7dF3dCEcC097f58B47053
gate owner()      0x762F96819a7705448843E96D63D638Ec2f39403B
gate pendingOwner() / delegate()   0x0
gate allowAll()   false
resolve(anyone)   (false, 0x0)
```

### Contract surface

```solidity
// SafeBindingRegistry — permissionless, write-once
function bind(address account, address safe) external;   // caller must be account or safe
function safeFor(address account) external view returns (address);

// SignetAuthResolver — immutable, ownerless
function resolve(address account) external view returns (bool ok, bytes32 subject);
function typeAndVersion() external pure returns (string memory);

// SFLuvAuthGate — owner: SFLuv multisig
function setAllowlisted(address[] calldata accounts, bool allowed) external;
function setAllowAll(bool) external;
function setDelegate(IAuthGate) external;   // rollout: swap curation for a chain-state policy
```

### Tests

```bash
forge test                                              # offline, 77 tests
CELO_RPC_URL=https://forno.celo.org forge test          # + Celo fork checks
BERA_RPC_URL=https://rpc.berachain.com forge test       # + Berachain wipe checks
```
