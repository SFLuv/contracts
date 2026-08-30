// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

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
 *      1. **Only the account may bind itself.** Every write is authorised by
 *         the account named in it — either because it is `msg.sender`, or
 *         because it signed an EIP-712 `Bind` struct that a relayer submitted.
 *         There is no owner, no role, no admin, and no path by which a third
 *         party writes a binding for an address it does not control.
 *
 *         This is the property the first version of this contract got wrong.
 *         It also accepted `msg.sender == safe`, reasoning that a Safe vouching
 *         for its own owner is self-authorising. It is not: the caller chooses
 *         which contract plays the part of the Safe, and `isOwner` is then
 *         answered by that same attacker-supplied contract. Anyone could pin
 *         any unbound EOA to an address of their choosing, and — because that
 *         version was also write-once — the victim could never correct it. The
 *         live `isOwner` re-check in the resolver does not help, because it
 *         interrogates the attacker's contract too. Asking the nominated Safe
 *         to vouch is circular; only the account can speak for itself.
 *
 *      2. **Validated at write time.** `isOwner(account)` must already hold, so
 *         a binding can never nominate a Safe the account has no claim on. This
 *         is belt-and-braces: the resolver checks it again at read time.
 *
 *      3. **Re-bindable, by the account alone.** A Signet key id embeds the
 *         subject (`resolver:<addr>:<subject>`), so moving a binding moves the
 *         namespace the account's *future* sessions land in. That is a real
 *         consequence, but it is the account's to choose, and making it
 *         impossible was worse: an account bound to the wrong Safe — or to a
 *         wallet it has since left — was permanently unusable, with no
 *         recourse, because this contract cannot be upgraded. Rebinding cannot
 *         be used to take anything: reaching a Safe requires already being one
 *         of its owners, which is a power the account had regardless.
 *
 *      Losing a wallet is therefore a new identity, deliberately: bind the new
 *      EOA to the *same* Safe and the subject is unchanged; bind it to a
 *      different Safe and it is a different principal, which is the truth.
 *
 *      Multiple accounts may bind to the same Safe. That is the point — it is
 *      how two logins (two Privy EOAs, both added as owners) converge on one
 *      subject.
 */
contract SafeBindingRegistry is ISafeBindingRegistry, EIP712 {
    mapping(address account => address safe) private _safeOf;

    /// @notice Replay counter for `bindWithSignature`, per account.
    mapping(address account => uint256) public nonces;

    /// @dev keccak256("Bind(address account,address safe,uint256 nonce,uint256 deadline)")
    bytes32 public constant BIND_TYPEHASH =
        keccak256("Bind(address account,address safe,uint256 nonce,uint256 deadline)");

    error ZeroAddress();
    error NotAnOwner(address account, address safe);
    error AlreadyBoundTo(address account, address safe);
    error SignatureExpired(uint256 deadline);
    error InvalidSignature();

    /// @param previousSafe address(0) on a first binding, else the Safe replaced.
    event SafeBound(address indexed account, address indexed safe, address indexed previousSafe);

    constructor() EIP712("SFLuvSafeBindingRegistry", "1") {}

    /// @inheritdoc ISafeBindingRegistry
    function safeFor(address account) external view returns (address safe) {
        return _safeOf[account];
    }

    /// @notice Bind the caller to a Safe it owns. Rebinding is allowed; binding
    ///         to the Safe already recorded reverts rather than burning gas.
    function bind(address safe) external {
        _bind(msg.sender, safe);
    }

    /**
     * @notice Bind `account` on its own written authority, submitted by anyone.
     *         The relayer pays the gas; the signature is what authorises the
     *         write. This exists because the accounts being bound are wallet
     *         signing keys that hold no CELO.
     * @param signature EIP-712 over `Bind(account,safe,nonce,deadline)`, by
     *        `account`. ERC-1271 accounts are accepted.
     */
    function bindWithSignature(address account, address safe, uint256 deadline, bytes calldata signature) external {
        if (account == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert SignatureExpired(deadline);

        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(BIND_TYPEHASH, account, safe, nonces[account], deadline)));
        if (!SignatureChecker.isValidSignatureNow(account, digest, signature)) revert InvalidSignature();

        // Consume the nonce before the external call in `_bind`, so a hostile
        // Safe re-entering cannot replay this signature.
        unchecked {
            ++nonces[account];
        }

        _bind(account, safe);
    }

    function _bind(address account, address safe) private {
        if (safe == address(0)) revert ZeroAddress();

        address previous = _safeOf[account];
        if (previous == safe) revert AlreadyBoundTo(account, safe);

        // Reverts if `safe` has no code, which is what we want: an undeployed
        // wallet cannot have answered honestly.
        if (!ISafe(safe).isOwner(account)) revert NotAnOwner(account, safe);

        _safeOf[account] = safe;
        emit SafeBound(account, safe, previous);
    }
}
