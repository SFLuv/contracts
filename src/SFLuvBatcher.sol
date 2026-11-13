// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SFLuvBatcher
 * @notice Pays many recipients from the caller's own SFLUV in one call.
 *
 *         Why it exists. The faucet pays out of a Safe through sponsored
 *         operations, and the paymaster sponsors an operation only when the
 *         call inside it targets a whitelisted contract. One operation makes one
 *         call, so paying thirty people at an event meant thirty operations.
 *         Batching through Safe's MultiSend would have meant whitelisting a
 *         contract that makes any call at all, for any account the paymaster
 *         sponsors.
 *
 *         This does one thing. It moves SFLUV that the caller holds, and has
 *         approved it to move, to the recipients the caller names. It is pinned
 *         to one token, has no owner, no upgrade path and no other function, and
 *         never holds a balance.
 *
 *         The allowance is safe to grant without a limit: tokens are only ever
 *         pulled from msg.sender, so an allowance given to this contract can be
 *         spent by nobody but the account that gave it, calling it itself.
 *         Whitelisting it on the paymaster therefore lets a sponsored account do
 *         nothing it could not already do with a plain transfer, several times
 *         over.
 */
contract SFLuvBatcher {
    using SafeERC20 for IERC20;

    /// @notice The one token this batcher moves.
    IERC20 public immutable token;

    /// @notice The most recipients one call pays. A bound on the gas a single
    ///         sponsored operation can spend, well above any burst the faucet
    ///         sees.
    uint256 public constant MAX_BATCH = 100;

    /// @notice One batch, paid in full. Each transfer also emits the token's
    ///         own Transfer(payer, recipient, amount).
    event BatchPaid(address indexed payer, uint256 count, uint256 total);

    error ZeroToken();
    error EmptyBatch();
    error BatchTooLarge(uint256 count);
    error LengthMismatch(uint256 recipients, uint256 amounts);
    error ZeroRecipient(uint256 index);

    constructor(IERC20 token_) {
        if (address(token_) == address(0)) revert ZeroToken();
        token = token_;
    }

    /**
     * @notice Transfers amounts[i] of the token from the caller to recipients[i].
     *         All or nothing: if any transfer fails, none happens.
     */
    function batchTransfer(address[] calldata recipients, uint256[] calldata amounts) external {
        uint256 count = recipients.length;
        if (count == 0) revert EmptyBatch();
        if (count > MAX_BATCH) revert BatchTooLarge(count);
        if (count != amounts.length) revert LengthMismatch(count, amounts.length);

        uint256 total;
        for (uint256 i; i < count; ++i) {
            if (recipients[i] == address(0)) revert ZeroRecipient(i);
            token.safeTransferFrom(msg.sender, recipients[i], amounts[i]);
            total += amounts[i];
        }

        emit BatchPaid(msg.sender, count, total);
    }
}
