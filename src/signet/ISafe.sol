// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice The single Safe view this system treats as authoritative.
/// @dev Citizen Wallet accounts are Safe 1.4.1 proxies (verified on Celo:
///      `VERSION() == "1.4.1"`). `isOwner` is also the exact predicate the
///      Citizen Wallet CommunityModule uses to authorize a user operation
///      (`UserOpHandler.validateUserOp` -> `OwnerManager.isOwner(signer)`), so
///      resolving on it grants a Signet session precisely the authority that
///      already moves the wallet's funds — no new privilege class.
interface ISafe {
    function isOwner(address owner) external view returns (bool);
}
