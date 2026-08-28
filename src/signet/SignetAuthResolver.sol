// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IAuthGate} from "./IAuthGate.sol";
import {ISafe} from "./ISafe.sol";
import {ISafeBindingRegistry} from "./ISafeBindingRegistry.sol";
import {ISignetAuthResolver} from "./ISignetAuthResolver.sol";

/**
 * @title SignetAuthResolver
 * @notice Answers, for a Signet group: "this address proved control of a key —
 *         whose account is it?" with the address of the Citizen Wallet Safe the
 *         account currently owns.
 *
 *         Authority is the Safe's live owner set, not a derivation and not the
 *         registry. The registry nominates a candidate Safe; `isOwner` decides.
 *         So a compromised or careless registry can deny service, or point an
 *         account at another Safe that account also owns — it can never hand
 *         one person's subject to another.
 *
 * @dev **Deployed IMMUTABLY.** The resolver address is half of every Signet key
 *      id (`resolver:<addr>:<subject>`) and Signet has no mechanic to migrate
 *      keys between resolver namespaces, so replacing this contract orphans
 *      every key created under it. Do not put it behind a proxy either: that
 *      would let the logic change without changing the namespace, defeating the
 *      protection the namespacing exists to provide. Everything expected to
 *      change over time — which Safe an account maps to, who is admitted — is
 *      pushed into the registry and the gate, which is why those are separate
 *      contracts and this one has no owner and no setters.
 *
 *      `resolve` MUST NOT revert (ISignetAuthResolver), so every external read
 *      is a raw `staticcall` with a strict length check rather than a typed call
 *      or try/catch: a call into a codeless address succeeds with empty
 *      returndata, and anything that is not exactly one word is treated as a
 *      failure. There is no path out of `resolve` that is not `return`.
 *
 *      Each read is also gas-capped. A Safe with a hostile fallback handler
 *      could otherwise burn until the node's `eth_call` cap — and providers do
 *      not agree on that cap, so one node would see a failure where another sees
 *      an answer, splitting the vote. Pinning `from = 0x0` and the read block
 *      (signet-protocol R-2/R-3) closes the sender and state channels; the gas
 *      cap closes this one.
 */
contract SignetAuthResolver is ISignetAuthResolver {
    /// @notice Account -> candidate Safe. A hint, re-validated on every resolve.
    ISafeBindingRegistry public immutable REGISTRY;

    /// @notice Optional admission policy. address(0) means open: any account
    ///         that owns the Safe it bound may open a session.
    IAuthGate public immutable GATE;

    /// @dev Ceiling on each external read. `safeFor` is one SLOAD; Safe 1.4.1's
    ///      `isOwner` is a delegatecall plus a mapping SLOAD (~6k). 100k leaves
    ///      an order of magnitude of headroom while keeping the whole `resolve`
    ///      far below any plausible node `eth_call` cap.
    uint256 private constant READ_GAS = 100_000;

    error RegistryRequired();

    constructor(ISafeBindingRegistry registry, IAuthGate gate) {
        if (address(registry) == address(0)) revert RegistryRequired();
        REGISTRY = registry;
        GATE = gate;
    }

    /// @inheritdoc ISignetAuthResolver
    function resolve(address account) external view returns (bool ok, bytes32 subject) {
        if (account == address(0)) return (false, bytes32(0));

        // Admission, when a gate is configured. Fails closed: a gate that
        // reverts, is undeployed, or answers malformed denies everyone rather
        // than admitting them.
        if (address(GATE) != address(0)) {
            (bool gateAnswered, bytes32 allowed) =
                _readWord(address(GATE), abi.encodeCall(IAuthGate.isAllowed, (account)));
            if (!gateAnswered || allowed == bytes32(0)) return (false, bytes32(0));
        }

        (bool bound, bytes32 raw) =
            _readWord(address(REGISTRY), abi.encodeCall(ISafeBindingRegistry.safeFor, (account)));
        if (!bound) return (false, bytes32(0));
        // Reject a dirty word rather than truncating it: a registry that
        // returned non-address junk is not one to derive a subject from.
        if (uint256(raw) > type(uint160).max) return (false, bytes32(0));

        address safe = address(uint160(uint256(raw)));
        if (safe == address(0)) return (false, bytes32(0));
        // An undeployed Safe cannot have answered isOwner honestly, and minting
        // a key against a wallet that does not exist yet is exactly the case
        // the enrolment flow assumes away.
        if (safe.code.length == 0) return (false, bytes32(0));

        (bool asked, bytes32 isOwner) = _readWord(safe, abi.encodeCall(ISafe.isOwner, (account)));
        if (!asked || isOwner == bytes32(0)) return (false, bytes32(0));

        return (true, bytes32(uint256(uint160(safe))));
    }

    /// @inheritdoc ISignetAuthResolver
    /// @dev MUST match Signet's accept-list verbatim
    ///      (`node/resolver.go:acceptedResolverVersions`). The list is a
    ///      protocol constant, not per-node config, so any other string — an
    ///      SFLuv-branded one included — fails auth on every node until a Signet
    ///      release adds it.
    function typeAndVersion() external pure returns (string memory) {
        return "SignetAuthResolver 1.0.0";
    }

    /// @dev One gas-capped word-sized static read. Returns ok=false rather than
    ///      bubbling anything: a revert, an empty return from a codeless
    ///      address, or a return that is not exactly 32 bytes all read as "no
    ///      answer".
    function _readWord(address target, bytes memory data) private view returns (bool ok, bytes32 word) {
        (bool success, bytes memory ret) = target.staticcall{gas: READ_GAS}(data);
        if (!success || ret.length != 32) return (false, bytes32(0));
        return (true, abi.decode(ret, (bytes32)));
    }
}
