// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {
    ERC20WrapperUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20WrapperUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SFLUVBeraWipe
 * @notice Berachain deprecation implementation. Phase 5 of the Celo migration.
 *
 *         When the v2 (or v2_1) proxy is upgraded to this contract, writes are
 *         immediately disabled but balances and backing assets remain in place.
 *         Governance can still upgrade back to the previous ERC20 implementation
 *         if Celo distribution verification fails.
 *
 *         After upgrade, every user-facing token method (transfer, transferFrom,
 *         approve, depositFor, withdrawTo) reverts with the migration message.
 *         `balanceOf` and `totalSupply` are hardcoded to 0 so RPC-polling tools stop
 *         reporting legacy Berachain balances. The remaining read-only methods (name,
 *         symbol, decimals, allowance) intentionally remain functional so block
 *         explorers and historical tooling continue to render the legacy state.
 *
 *         The point of no return is the later owner-gated `sweepBacking` call,
 *         which transfers all underlying ERC20 (HONEY) balance directly from the
 *         proxy to treasury, bypassing ERC20Wrapper accounting and the
 *         REDEEMER_ROLE path. This is intentionally asynchronous so operators can
 *         verify Celo migration outputs before sweeping Berachain backing assets.
 *
 *         Storage safety:
 *         - Inherits the same parent chain in the same order as SFLUVv2 /
 *           SFLUVv2_1 so OZ namespaced storage slots remain consistent. (OZ v5
 *           uses ERC-7201 namespaced storage, so this is belt-and-suspenders;
 *           keeping the order minimizes audit confusion.)
 *         - Adds one new bool in its own ERC-7201 namespace; cannot collide.
 */
contract SFLUVBeraWipe is ERC20WrapperUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    string private constant MIGRATION_MESSAGE = "SFLuv has migrated to CELO.";

    /// @custom:storage-location erc7201:sfluv.storage.BeraWipe
    struct BeraWipeStorage {
        bool backingSwept;
    }

    // keccak256(abi.encode(uint256(keccak256("sfluv.storage.BeraWipe")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BeraWipeStorageLocation =
        0x013d9618d48a920f45a9effaa7f3a5d016f556300e8e3e1f756472c0fe2bb100;

    function _wipeStore() private pure returns (BeraWipeStorage storage $) {
        assembly {
            $.slot := BeraWipeStorageLocation
        }
    }

    // --- Events / errors ---

    event BackingSwept(address indexed treasury, address indexed underlyingToken, uint256 amountSwept);

    error BackingAlreadySwept();
    error SweepTransferFailed();
    error ZeroTreasury();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // --- UUPS ---

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // --- Sweep backing (one-shot, irreversible) ---

    /**
     * @notice Sweep all underlying ERC20 balance to `treasury`.
     *         Run only after Celo migration has been independently verified.
     */
    function sweepBacking(address treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury == address(0)) revert ZeroTreasury();
        BeraWipeStorage storage $ = _wipeStore();
        if ($.backingSwept) revert BackingAlreadySwept();
        $.backingSwept = true;

        IERC20 backing = underlying();
        uint256 amount = backing.balanceOf(address(this));
        if (amount > 0) {
            // Direct transfer from proxy context; not via withdrawTo. Per runbook.
            bool ok = backing.transfer(treasury, amount);
            if (!ok) revert SweepTransferFailed();
        }

        emit BackingSwept(treasury, address(backing), amount);
    }

    function backingSwept() external view returns (bool) {
        return _wipeStore().backingSwept;
    }

    function wiped() external view returns (bool) {
        return _wipeStore().backingSwept;
    }

    // --- User-facing reverts ---

    function transfer(address, uint256) public pure override returns (bool) {
        revert(MIGRATION_MESSAGE);
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert(MIGRATION_MESSAGE);
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert(MIGRATION_MESSAGE);
    }

    function depositFor(address, uint256) public pure override returns (bool) {
        revert(MIGRATION_MESSAGE);
    }

    function withdrawTo(address, uint256) public pure override returns (bool) {
        revert(MIGRATION_MESSAGE);
    }

    /// @notice Hardcoded to 0 so wallets and other RPC-polling tools stop showing
    ///         legacy Berachain balances after the Celo migration. Does not clear the
    ///         underlying balance storage and emits no events -- see the note below.
    function balanceOf(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Hardcoded to 0 alongside `balanceOf` so the ERC-20 invariant
    ///         sum(balanceOf) == totalSupply still holds for RPC readers. Backing was
    ///         already swept, so the reported supply was unbacked regardless. Like
    ///         `balanceOf`, this does not clear storage and emits no events.
    function totalSupply() public pure override returns (uint256) {
        return 0;
    }

    // Remaining read-only methods (name, symbol, decimals, allowance, hasRole, etc.)
    // inherit unchanged from the parent contracts so explorers and legacy tools
    // continue to render the historical state.
    //
    // NOTE: balanceOf and totalSupply are hardcoded to 0, but the underlying balance
    // storage is left intact and no burn/Transfer events are emitted. Event-derived
    // indexers (Ponder, subgraphs, Etherscan-family holder tables) therefore still
    // report the legacy balances. Clearing those requires an actual burn pass via
    // SFLUVv2_1.migrate(), which emits Transfer-to-zero per holder.
}
