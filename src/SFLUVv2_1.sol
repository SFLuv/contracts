// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20WrapperUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20WrapperUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ISFLUVErrors} from "./ISFLUVErrors.sol";

/**
 * @title SFLUVv2_1
 * @notice One-shot upgrade of SFLUVv2 that adds the off-ramp needed to migrate to v3
 *         on a different chain. Inheritance order and existing roles/storage are
 *         preserved exactly so the v2 proxy can be upgraded in place.
 *
 *         New surface:
 *           - MIGRATOR_ROLE                   — grant to the address running the migration.
 *           - pause() / unpause() / paused()  — gated by DEFAULT_ADMIN_ROLE (governance).
 *           - migrate(holders, amounts)       — burns each holder's balance, with a
 *                                                strict equality check vs. the snapshot.
 *
 *         Semantics of `paused`:
 *           - mints and transfers revert (so wraps via depositFor and ordinary
 *             user-to-user transfers are blocked while the snapshot is locked in);
 *           - burns are allowed (so migrate() and withdrawTo() still work).
 *
 *         This is intended as a terminal v2 upgrade: after migration the contract
 *         sits at zero supply, paused, with HONEY drained to treasury.
 */
contract SFLUVv2_1 is ERC20WrapperUpgradeable, AccessControlUpgradeable, UUPSUpgradeable, ISFLUVErrors {
    // --- Existing v2 roles, preserved bytewise so off-chain tooling is unchanged. ---
    bytes32 public constant MINTER_ROLE = keccak256("MINTER");
    bytes32 public constant MINTER_ADMIN_ROLE = keccak256("MINTER_ADMIN");
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER");
    bytes32 public constant REDEEMER_ADMIN_ROLE = keccak256("REDEEMER_ADMIN");

    // --- New: migration role. Defaults to DEFAULT_ADMIN_ROLE as its admin (OZ default),
    //     which is governance — so no reinitializer call is needed after upgrade. ---
    bytes32 public constant MIGRATOR_ROLE = keccak256("MIGRATOR");

    /// @custom:storage-location erc7201:sfluv.storage.SFLUVv2_1
    struct SFLUVv2_1Storage {
        bool paused;
    }

    // keccak256(abi.encode(uint256(keccak256("sfluv.storage.SFLUVv2_1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SFLUVv2_1StorageLocation =
        0x2699b41ee154ae475c5a57532884e8504e439a61e518fc2c5c2b56ae68765700;

    function _v2_1Storage() private pure returns (SFLUVv2_1Storage storage $) {
        assembly {
            $.slot := SFLUVv2_1StorageLocation
        }
    }

    // --- Events ---

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    /// @notice Emitted once per holder when their balance is force-burned for the cross-chain migration.
    event Migrated(address indexed holder, uint256 amount);
    /// @notice Emitted when the residual underlying ERC20 is swept post-migration.
    event UnderlyingSwept(address indexed to, uint256 amount);

    // --- Errors ---

    error TransfersPaused();
    error LengthMismatch();
    error BalanceMismatch(address holder, uint256 expected, uint256 actual);
    error EmptyBatch();
    error OutstandingSupply(uint256 totalSupply);
    error SweepFailed();
    error ZeroTo();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // --- UUPS ---

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // --- Wrap / redeem (gated identically to v2) ---

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

    // --- Pause ---

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _v2_1Storage().paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _v2_1Storage().paused = false;
        emit Unpaused(msg.sender);
    }

    function paused() external view returns (bool) {
        return _v2_1Storage().paused;
    }

    /**
     * @dev While paused, block mints (`from == 0`) and transfers, but allow burns
     *      (`to == 0`) so migrate() and withdrawTo() still function.
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        if (_v2_1Storage().paused && to != address(0)) {
            revert TransfersPaused();
        }
        super._update(from, to, value);
    }

    // --- Migration ---

    /**
     * @notice Burn each holder's full balance, with a strict equality check vs. the
     *         snapshot. Off-chain reconciliation should sum `Migrated` events and
     *         compare to the snapshot totals before minting on v3.
     *
     * @dev Pause SHOULD be set before calling so balances cannot drift across batches.
     *      This function does not require paused == true on its own, in case you need
     *      to run a final cleanup batch in a special situation.
     *
     * @param holders Addresses to burn.
     * @param amounts Expected balance of each holder; reverts on mismatch.
     */
    function migrate(address[] calldata holders, uint256[] calldata amounts)
        external
        onlyRole(MIGRATOR_ROLE)
    {
        uint256 n = holders.length;
        if (n == 0) revert EmptyBatch();
        if (n != amounts.length) revert LengthMismatch();

        for (uint256 i = 0; i < n; ++i) {
            address h = holders[i];
            uint256 expected = amounts[i];
            uint256 actual = balanceOf(h);
            if (actual != expected) revert BalanceMismatch(h, expected, actual);
            _burn(h, actual);
            emit Migrated(h, actual);
        }
    }

    /**
     * @notice Sweep the residual underlying ERC20 (HONEY) to `to`, bypassing the
     *         wrapper's withdrawTo path.
     *
     * @dev    After migrate() burns every holder's balance, the wrapper's
     *         withdrawTo can't be used to drain the underlying because it burns
     *         from msg.sender — and no one holds SFLUV anymore. This function
     *         exists for exactly that case: a direct ERC20.transfer from the
     *         proxy context, guarded so it can only fire when totalSupply == 0.
     *         The guard ensures the underlying that backs any still-outstanding
     *         SFLUV cannot be removed from under users.
     *
     * @param  to  Destination address for the residual underlying balance.
     */
    function sweepUnderlying(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroTo();
        uint256 supply = totalSupply();
        if (supply != 0) revert OutstandingSupply(supply);

        IERC20 backing = underlying();
        uint256 amount = backing.balanceOf(address(this));
        if (amount > 0) {
            bool ok = backing.transfer(to, amount);
            if (!ok) revert SweepFailed();
        }
        emit UnderlyingSwept(to, amount);
    }
}
