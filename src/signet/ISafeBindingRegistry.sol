// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice Read side of the account -> Safe binding consumed by the resolver.
interface ISafeBindingRegistry {
    /// @return safe The Safe this account is bound to, or address(0) if unbound.
    function safeFor(address account) external view returns (address safe);
}
