// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IAuthGate} from "../../src/signet/IAuthGate.sol";
import {ISafe} from "../../src/signet/ISafe.sol";
import {ISafeBindingRegistry} from "../../src/signet/ISafeBindingRegistry.sol";

/// @dev Minimal stand-in for a Citizen Wallet Safe: a mutable owner set, which
///      is the only Safe state the resolver reads, plus the enabled-module set
///      a membership delegate would read.
contract MockSafe is ISafe {
    mapping(address => bool) internal _owners;
    mapping(address => bool) internal _modules;

    constructor(address initialOwner) {
        _owners[initialOwner] = true;
    }

    function setOwner(address owner, bool isOwner_) external {
        _owners[owner] = isOwner_;
    }

    function setModule(address module, bool enabled) external {
        _modules[module] = enabled;
    }

    function isOwner(address owner) external view returns (bool) {
        return _owners[owner];
    }

    function isModuleEnabled(address module) external view returns (bool) {
        return _modules[module];
    }
}

interface ISafeModules {
    function isModuleEnabled(address module) external view returns (bool);
}

/// @dev The delegate shape SFLuv would deploy at rollout: membership answered
///      from chain state rather than a curated list — "is this account's bound
///      Safe running the community's module?". Deliberately not defensive; the
///      gate is what isolates a delegate that reverts.
contract ModuleMembershipGate is IAuthGate {
    ISafeBindingRegistry public immutable REGISTRY;
    address public immutable MODULE;

    constructor(ISafeBindingRegistry registry, address module) {
        REGISTRY = registry;
        MODULE = module;
    }

    function isAllowed(address account) external view returns (bool) {
        address safe = REGISTRY.safeFor(account);
        if (safe == address(0)) return false;
        return ISafeModules(safe).isModuleEnabled(MODULE);
    }
}

/// @dev Answers `isOwner` by folding in msg.sender — the local mirror of
///      signet-protocol's MockAuthResolver.senderSensitive. Used to prove the
///      resolver's own answer is sender-independent even when what it reads
///      is not.
contract SenderSensitiveSafe is ISafe {
    function isOwner(address) external view returns (bool) {
        return uint160(msg.sender) % 2 == 0;
    }
}

/// @dev Reverts on every read.
contract RevertingCallee {
    error Nope();

    fallback() external {
        revert Nope();
    }
}

/// @dev Returns fewer than 32 bytes.
contract ShortReturnCallee {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 4)
        }
    }
}

/// @dev Returns a very large buffer, to show oversized returndata is rejected
///      rather than decoded (and cannot blow up the caller).
contract HugeReturnCallee {
    fallback() external {
        assembly {
            return(0, 8192)
        }
    }
}

/// @dev Burns every unit of gas it is given.
contract GasBurnerCallee {
    fallback() external {
        assembly {
            for {} 1 {} {}
        }
    }
}

/// @dev A registry whose stored word has dirty high bits — not a clean address.
contract DirtyWordRegistry {
    fallback() external {
        assembly {
            mstore(0, not(0))
            return(0, 32)
        }
    }
}

/// @dev Registry test double with a directly settable mapping, so resolver
///      tests can construct states the real registry forbids (e.g. pointing at
///      a Safe the account does not own).
contract MockRegistry is ISafeBindingRegistry {
    mapping(address => address) internal _safeOf;

    function set(address account, address safe) external {
        _safeOf[account] = safe;
    }

    function safeFor(address account) external view returns (address) {
        return _safeOf[account];
    }
}

/// @dev Gate that denies everyone, to check the closed path.
contract DenyAllGate is IAuthGate {
    function isAllowed(address) external pure returns (bool) {
        return false;
    }
}
