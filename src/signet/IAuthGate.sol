// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice Optional admission policy consulted by SignetAuthResolver.
/// @dev A gate can only *deny*. It never influences which Safe an account
///      resolves to, so a compromised gate can admit addresses that should not
///      be admitted (and DoS ones that should) but can never redirect an
///      existing subject. That asymmetry is what makes it safe to leave the
///      gate mutable while the resolver stays immutable.
interface IAuthGate {
    function isAllowed(address account) external view returns (bool);
}
