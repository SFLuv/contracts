// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20WrapperUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20WrapperUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC3009Upgradeable} from "./ERC3009Upgradeable.sol";
import {ISFLUVErrors} from "./ISFLUVErrors.sol";

/**
 * @title SFLUVv3
 * @notice Fresh deployment of SFLUV adding EIP-3009 (Transfer With Authorization) and
 *         EIP-2612 (Permit) on top of the existing wrap/redeem semantics from v2.
 *
 *         This is NOT an upgrade of the v2 proxy — it is a new deployment.
 *
 *         Inherits:
 *           - ERC20WrapperUpgradeable  (wrap/unwrap underlying HONEY)
 *           - AccessControlUpgradeable (MINTER / REDEEMER roles, unchanged from v2)
 *           - UUPSUpgradeable          (so future patches are possible)
 *           - ERC20PermitUpgradeable   (EIP-2612 signed allowances)
 *           - ERC3009Upgradeable       (EIP-3009 signed transfers, w/ EIP-1271 support)
 */
contract SFLUVv3 is
    ERC20WrapperUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ERC20PermitUpgradeable,
    ERC3009Upgradeable,
    ISFLUVErrors
{
    // Unchanged from v2 — keep the same role identifiers so off-chain tooling /
    // role-grant scripts remain compatible.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER");
    bytes32 public constant MINTER_ADMIN_ROLE = keccak256("MINTER_ADMIN");
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER");
    bytes32 public constant REDEEMER_ADMIN_ROLE = keccak256("REDEEMER_ADMIN");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Pick the EIP-712 `name` to match the ERC-20 `name()` so wallets show the same
     *      string in the signing UI. The `version` is pinned to "1" forever — changing it
     *      would invalidate every prior off-chain signature.
     */
    function initialize(address _governance, IERC20 _underlyingToken) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        __ERC20_init("SFLUV V3.0", "SFLUV");
        __ERC20Wrapper_init(_underlyingToken);

        __EIP712_init("SFLUV V3.0", "1");
        __ERC20Permit_init("SFLUV V3.0");
        __ERC3009_init();

        if (_governance == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, _governance);

        _setRoleAdmin(MINTER_ROLE, MINTER_ADMIN_ROLE);
        _setRoleAdmin(REDEEMER_ROLE, REDEEMER_ADMIN_ROLE);
    }

    // --- UUPS ---

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // --- Wrap / redeem (role-gated, unchanged from v2) ---

    function depositFor(address account, uint256 amount)
        public
        override
        onlyRole(MINTER_ROLE)
        returns (bool)
    {
        return super.depositFor(account, amount);
    }

    function withdrawTo(address account, uint256 amount)
        public
        override
        onlyRole(REDEEMER_ROLE)
        returns (bool)
    {
        return super.withdrawTo(account, amount);
    }

    // --- Multiple-inheritance overrides ---

    /// @dev `decimals` is defined by both ERC20Upgradeable (default 18) and
    ///      ERC20WrapperUpgradeable (defers to the underlying token). Disambiguate
    ///      by deferring to the wrapper, which preserves v2 behavior (matches HONEY).
    function decimals()
        public
        view
        virtual
        override(ERC20Upgradeable, ERC20WrapperUpgradeable)
        returns (uint8)
    {
        return ERC20WrapperUpgradeable.decimals();
    }

    /// @dev ERC-165: advertise AccessControl + ERC-3009.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlUpgradeable, ERC3009Upgradeable)
        returns (bool)
    {
        return
            AccessControlUpgradeable.supportsInterface(interfaceId) ||
            ERC3009Upgradeable.supportsInterface(interfaceId);
    }
}
