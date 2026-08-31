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
| `SafeBindingRegistry` | **immutable**, permissionless | Records account → Safe. Every write authorised by the account itself; no admin. |
| `SFLuvAuthGate` | mutable, owned by SFLuv | Admission policy. Can only deny. |

---

## Who does what

| # | Work | Owner | Blocks |
|---|---|---|---|
| A | ~~Deploy on Celo~~ — **done** (redeployed after a vulnerability in the first registry) | SFLuv | D |
| B | Node config on all six nodes | OLL (4 nodes) + SFLuv (2 nodes) | D |
| C | Client support for the `onchain_resolver` scheme — **does not exist in the SDK today** | OLL (SDK) or SFLuv (app) | E |
| D | Bind the resolver to the group (manager, timelocked) | SFLuv (group manager) | E |
| E | App enrolment + login flow | SFLuv | — |

A, B and C are independent and can run in parallel. **D must come after B**: the
moment the binding executes, any node without Celo RPC starts failing auth.

---

## A. Deploy the contracts (SFLuv, Celo) — ✅ DONE 2026-08-30

Live at Celo block **76237369**. The first deployment (block 76208199) shipped a
registry with a **squatting vulnerability**; it was found before anything was
bound, so the replacement cost only gas and orphaned no keys. The gate was not
affected and was carried across untouched, allowlist included.

| Contract | Address | |
|---|---|---|
| `SignetAuthResolver` | [`0x903409cB9248b1f0047c5F967a3db8E03Df3E11a`](https://celoscan.io/address/0x903409cB9248b1f0047c5F967a3db8E03Df3E11a#code) | new |
| `SafeBindingRegistry` | [`0xd35A40c49c6FAfD8a3B193146726A7B3a97e9BBa`](https://celoscan.io/address/0xd35A40c49c6FAfD8a3B193146726A7B3a97e9BBa#code) | new |
| `SFLuvAuthGate` | [`0x78B405B629e7c27F81d7dF3dCEcC097f58B47053`](https://celoscan.io/address/0x78B405B629e7c27F81d7dF3dCEcC097f58B47053#code) | unchanged |

Verified on the live pair (`test/LiveDeploymentForkCelo.t.sol`, 9 tests): the
resolver points at the new registry and the existing gate, the gate still holds
its owner and staff allowlist, an unbound account is denied, binding resolves to
the Safe, `bindWithSignature` works from an unrelated relayer, a lying Safe
cannot squat an EOA, and a wrong binding can be corrected.

### The squatting vulnerability

The retired registry authorised a write from either the account or *the Safe it
names*, then asked that same Safe whether it owned the account:

```solidity
if (msg.sender != account && msg.sender != safe) revert NotSelfAuthorized(msg.sender);
...
if (!ISafe(safe).isOwner(account)) revert NotAnOwner(account, safe);
```

Both halves are chosen by the caller. Anyone could deploy a contract whose
`isOwner` returns `true` for everybody, call `bind(victimEOA, thatContract)`
from it, and permanently pin any unbound EOA to an address of their choosing —
for the cost of one transaction, against any address they could read off the
chain. The victim would then authenticate successfully, but under a subject the
attacker picked rather than their own Safe; and because that registry was also
write-once, they could never correct it.

The live `isOwner` re-check in the resolver does **not** cover this. It defends
against a lying *registry*, but here the attacker supplies the contract playing
the part of the Safe, so the check interrogates the attacker. "The registry
nominates, the Safe decides" holds only when the Safe is not the attacker's
choice. Requiring a *genuine* Safe would not have fixed it either — Safe lets
an owner add any address without its consent, so the same attack runs through a
real wallet.

Both behaviours are now permanent regression tests in
`test/SafeBindingRegistry.t.sol`.

### What changed

| | Retired | Replacement |
|---|---|---|
| Who may write a binding | the account **or the named Safe** | the account only — directly, or by EIP-712 signature it produced |
| Gasless enrolment | Safe relays via CommunityModule, and that call *is* the authority | same CommunityModule relay, but the account's signature is the authority — any relayer works |
| Correcting a wrong binding | impossible, write-once | the account may rebind |
| Replay protection | n/a | per-account nonce + deadline + EIP-712 domain |

`SignetAuthResolver` is unchanged in behaviour, but it holds the registry
address as an immutable, so a new registry means a new resolver.
**`SFLuvAuthGate` is not affected and is reused as-is**, keeping its owner and
the staff allowlist already written to it.

### The deploy, as run

```bash
EXPECTED_CHAIN_ID=42220 \
GATE_ADDRESS=0x78B405B629e7c27F81d7dF3dCEcC097f58B47053 \
forge script script/DeploySignetResolver.s.sol:DeploySignetResolver \
  --rpc-url https://forno.celo.org --private-key $PRIVATE_KEY --broadcast
```

`GATE_ADDRESS` reuses the deployed gate rather than making a new one; the script
asserts it has code, and asserts the resolver's `REGISTRY()`/`GATE()` match what
was just deployed. Two transactions, 0.34 CELO.

**Retired, do not use:** registry `0xAa42790F…CD85`, resolver `0x0571e773…6ce3`.
They are still deployed and still verified on Celoscan; nothing was ever bound
to them.

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
RES=0x903409cB9248b1f0047c5F967a3db8E03Df3E11a
cast call $RES "typeAndVersion()(string)" --rpc-url $R
# → "SignetAuthResolver 1.0.0"   (exactly; anything else is rejected by every node)
cast call $RES "REGISTRY()(address)"      --rpc-url $R   # → 0xd35A40…9BBa
cast call $RES "GATE()(address)"          --rpc-url $R   # → 0x78B405…7053
cast call $RES "resolve(address)(bool,bytes32)" <unbound eoa> --rpc-url $R
# → false, 0x0…0   (nothing resolves until allowlisted *and* bound — expected)

# The registry's EIP-712 domain, which the app must reproduce exactly
cast call 0xd35A40c49c6FAfD8a3B193146726A7B3a97e9BBa \
  "eip712Domain()(bytes1,string,string,uint256,address,bytes32,uint256[])" --rpc-url $R
# → "SFLuvSafeBindingRegistry", "1", 42220, 0xd35A40…9BBa
```

Identify contracts by their **getters, not by a pasted deploy log** — `forge`'s
printed summary transposed the registry and gate names on this deploy, though
its `run-latest.json` was correct. The gate answers `owner()`; the registry
answers `safeFor()`.

### Source verification — done

All three are verified on Celoscan, so the resolver's logic can be read
alongside this document rather than taken on trust. The invocations, for
re-verification or for a redeploy elsewhere:

```bash
export ETHERSCAN_API_KEY=<key>   # Etherscan V2: one key covers Celo

# Registry first — no constructor args
forge verify-contract 0xd35A40c49c6FAfD8a3B193146726A7B3a97e9BBa \
  src/signet/SafeBindingRegistry.sol:SafeBindingRegistry \
  --chain 42220 --watch

# Resolver — (registry, gate), the order the constructor declares
forge verify-contract 0x903409cB9248b1f0047c5F967a3db8E03Df3E11a \
  src/signet/SignetAuthResolver.sol:SignetAuthResolver \
  --chain 42220 --watch \
  --constructor-args 0x000000000000000000000000d35a40c49c6fafd8a3b193146726a7b3a97e9bba00000000000000000000000078b405b629e7c27f81d7df3dcecc097f58b47053

# The gate was not redeployed; it is already verified.
```

Order matters only for readability: verifying the resolver first would leave its
`REGISTRY()`/`GATE()` pointing at unverified addresses, which is the same
confusion the transposed deploy log already caused once.

Compiler settings come from `foundry.toml` — solc 0.8.35, **optimizer off**. The
build targets `evmVersion: osaka`; if a future toolchain or verifier does not
offer it, pin `--evm-version prague` (or `cancun`). None of these contracts use
post-Cancun opcodes, so the bytecode is unchanged by that choice.

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
RESOLVER=0x903409cB9248b1f0047c5F967a3db8E03Df3E11a
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

Nothing resolves until an account is bound. Every binding is authorised by the
**account itself** — there is no admin path, and no path by which anyone else
writes a binding for an address they do not control, so SFLuv cannot prefill
bindings from the database. Two ways in:

```solidity
// The owner EOA sends the transaction itself. Needs CELO for gas.
bind(address safe)

// Anyone relays it; the account's signature is the authority. Gasless for
// the user, which is the production path — Privy EOAs hold no CELO.
bindWithSignature(address account, address safe, uint256 deadline, bytes signature)
```

The signature is EIP-712 over `Bind(address account,address safe,uint256 nonce,
uint256 deadline)`, signed by `account`. The domain is
`{name: "SFLuvSafeBindingRegistry", version: "1", chainId: 42220,
verifyingContract: <registry>}`, so a signature cannot be replayed against
another chain or another deployment of the registry. Read the current nonce from
`nonces(account)`; it increments on every successful signed bind. ERC-1271
signers are accepted.

Requirements at bind time: `isOwner(account)` must already hold on the named
Safe, and `safe` may not be zero or codeless. Bind the wallet the user considers
primary; `users.smart_index` identifies which one.

**Rebinding is allowed, by the account alone.** Re-pointing changes the subject
the account's *future* sessions land under, so keys minted under the old subject
stay addressable only there — treat it as a deliberate identity move, not a
routine correction. It exists so that binding the wrong Safe is recoverable
rather than permanent.

> **The Safe may still relay this; only its authority was removed.**
> `bindWithSignature` never reads `msg.sender` — the signature is the whole
> authorisation — so the wallet can keep submitting the binding through the
> CommunityModule, the sponsored rail it already uses. `execSponsored` needs no
> change; only the calldata differs. **Do not build a separate relayer.**
>
> What went away is the Safe being *self-authorising*. An earlier version of the
> registry accepted `msg.sender == safe` with no signature, on the reasoning
> that a wallet vouching for its own owner speaks for it. It does not — the
> caller chooses which contract plays the part of the Safe, and `isOwner` is
> then answered by that same contract. See *The squatting vulnerability* under
> workstream A. The new app work is producing the signature, not moving the
> transaction.

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
| `SignetAuthResolver` | Celo | [`0x903409cB9248b1f0047c5F967a3db8E03Df3E11a`](https://celoscan.io/address/0x903409cB9248b1f0047c5F967a3db8E03Df3E11a#code) |
| `SafeBindingRegistry` | Celo | [`0xd35A40c49c6FAfD8a3B193146726A7B3a97e9BBa`](https://celoscan.io/address/0xd35A40c49c6FAfD8a3B193146726A7B3a97e9BBa#code) |
| `SFLuvAuthGate` | Celo | [`0x78B405B629e7c27F81d7dF3dCEcC097f58B47053`](https://celoscan.io/address/0x78B405B629e7c27F81d7dF3dCEcC097f58B47053#code) |
| Gate owner / group manager | Celo + mainnet | `0x762F96819a7705448843E96D63D638Ec2f39403B` |

Deployed 2026-08-30 at Celo block **76237369**, from `0xcD44c7b9AeA6b90375a3888C02F70618d3387379`. The resolver address is half of
every Signet key id and can never change without orphaning keys.

> **Identify these contracts by their getters, not by a pasted deploy log.** On
> the first deploy, `forge`'s printed terminal summary transposed the registry
> and gate names — only that one block was wrong, and `run-latest.json` was
> correct throughout, so `forge verify-contract` still labelled them properly.
> The gate answers `owner()`; the registry answers `safeFor()`; the resolver
> answers `typeAndVersion()`.

Deployment state at hand-off — closed and inert, nothing resolves yet:

```
typeAndVersion()  "SignetAuthResolver 1.0.0"   exact accept-list match
REGISTRY()        0xd35A40c49c6FAfD8a3B193146726A7B3a97e9BBa
GATE()            0x78B405B629e7c27F81d7dF3dCEcC097f58B47053
registry domain   "SFLuvSafeBindingRegistry" / "1" / 42220 / 0xd35A40…9BBa
gate owner()      0x762F96819a7705448843E96D63D638Ec2f39403B
gate pendingOwner() / delegate()   0x0
gate allowAll()   false
gate allowlist    0x4aB013e7537F9F419127c6C787ca0951158cF40b  (test wallet owner)
safeFor(anyone)   0x0   nothing bound yet
resolve(anyone)   (false, 0x0)
```

### Contract surface

```solidity
// SafeBindingRegistry — permissionless; every write authorised by the account
function bind(address safe) external;                    // caller is the account
function bindWithSignature(address account, address safe, uint256 deadline, bytes signature) external;
function nonces(address account) external view returns (uint256);
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
