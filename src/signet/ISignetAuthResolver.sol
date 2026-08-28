// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ISignetAuthResolver
/// @notice Vendored verbatim from signet-protocol
///         (`contracts/contracts/interfaces/ISignetAuthResolver.sol`). Signet
///         ships only the interface and a mock; concrete adapters live in the
///         implementer's repo — this one.
///
///         One Signet-defined interface that an on-chain identity authority (or
///         a thin adapter wrapping one) implements so a Signet group can gate
///         session creation on it.
///
///         This is the *auth* lane — "who may open a session" — a sibling of the
///         group's trusted OAuth issuers, NOT of key scopes (which constrain what
///         a key may sign).
interface ISignetAuthResolver {
    /// @notice Authorize + resolve an address in a single view call.
    /// @dev MUST be a non-reverting view and a pure function of chain state at a
    ///      block (no per-call randomness, no branching on msg.sender/tx.origin),
    ///      so independent Signet nodes reading at the same pinned block agree.
    ///      Return ok=false on any failure rather than reverting.
    /// @param account The address recovered from the caller's SIWE signature.
    /// @return ok      Whether this address may open a session for the group.
    /// @return subject Canonical principal to namespace the session under.
    ///                 bytes32(0) = authorized but no canonical id (the group's
    ///                 requireCanonicalSubject flag decides whether that is
    ///                 acceptable).
    function resolve(address account) external view returns (bool ok, bytes32 subject);

    /// @notice Type + semantic version string, so nodes can refuse unknown
    ///         resolver versions. Convention follows Chainlink's
    ///         "Name 1.0.0" form.
    function typeAndVersion() external pure returns (string memory);
}
