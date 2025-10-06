// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface ISFLUVZapperErrors {
    // Signature: 0xd92e233d
    error ZeroAddress();

    error TransferFailed(address token, address to, address from, uint256 value);
    error MintFailed();
    error RedeemFailed();
}