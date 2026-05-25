// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title ERC3009Upgradeable
 * @notice EIP-3009 "Transfer With Authorization" extension for an upgradeable ERC-20.
 *         Supports both ECDSA (EOA) and EIP-1271 (smart-contract wallet, incl. EIP-7702
 *         delegated EOAs) signatures via OpenZeppelin's `SignatureChecker`.
 *
 *         This abstract contract is meant to be inherited alongside `ERC20Upgradeable`
 *         (or any descendant such as `ERC20WrapperUpgradeable`). The inheriting contract
 *         is responsible for calling `__ERC3009_init` (and `__EIP712_init`) from its
 *         own initializer.
 *
 *         Storage uses the ERC-7201 namespaced layout to remain safe across upgrades.
 *
 *         Spec: https://eips.ethereum.org/EIPS/eip-3009
 */
abstract contract ERC3009Upgradeable is Initializable, ERC20Upgradeable, EIP712Upgradeable, IERC165 {
    // keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;

    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    // keccak256("CancelAuthorization(address authorizer,bytes32 nonce)")
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        0x158b0a9edf7a828aad02f63cd515c68ef2f50ba807396f6d12842833a1597429;

    /// @custom:storage-location erc7201:sfluv.storage.ERC3009
    struct ERC3009Storage {
        // authorizer => nonce => used
        mapping(address => mapping(bytes32 => bool)) authorizationStates;
    }

    // keccak256(abi.encode(uint256(keccak256("sfluv.storage.ERC3009")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC3009StorageLocation =
        0xf3fe0dfb54e64feb31a162f59ae8996d302944a4cec953cd7f47edc745bfc300;

    function _getERC3009Storage() private pure returns (ERC3009Storage storage $) {
        assembly {
            $.slot := ERC3009StorageLocation
        }
    }

    // --- Events (per EIP-3009) ---

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    // --- Errors ---

    /// @dev Signature is not yet valid (current time <= validAfter).
    error ERC3009AuthorizationNotYetValid(uint256 validAfter);
    /// @dev Signature has expired (current time >= validBefore).
    error ERC3009AuthorizationExpired(uint256 validBefore);
    /// @dev Nonce has already been used or canceled for this authorizer.
    error ERC3009AuthorizationUsed(address authorizer, bytes32 nonce);
    /// @dev Signature did not recover to the authorizer.
    error ERC3009InvalidSignature(address authorizer);
    /// @dev `msg.sender` must equal `to` for receiveWithAuthorization.
    error ERC3009CallerNotPayee(address caller, address to);

    // --- Initializer ---

    function __ERC3009_init() internal onlyInitializing {}

    function __ERC3009_init_unchained() internal onlyInitializing {}

    // --- External / public ---

    /**
     * @notice Returns whether the given (authorizer, nonce) pair has been used or canceled.
     */
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _getERC3009Storage().authorizationStates[authorizer][nonce];
    }

    /**
     * @notice Execute a transfer with a signed authorization.
     * @dev Subject to the front-running concern noted in EIP-3009: anyone observing the
     *      signed payload can submit it. Prefer `receiveWithAuthorization` when the
     *      recipient/relayer matters.
     */
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _transferWithAuthorization(from, to, value, validAfter, validBefore, nonce, abi.encodePacked(r, s, v));
    }

    /**
     * @notice Execute a transfer with a signed authorization, with `bytes`-encoded signature.
     * @dev Overload that accepts EIP-1271 / EIP-2098 compact signatures.
     */
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        _transferWithAuthorization(from, to, value, validAfter, validBefore, nonce, signature);
    }

    /**
     * @notice Execute a transfer with a signed authorization; the caller MUST be the payee.
     * @dev Closes the front-running hole in `transferWithAuthorization` by requiring
     *      msg.sender == to.
     */
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _receiveWithAuthorization(from, to, value, validAfter, validBefore, nonce, abi.encodePacked(r, s, v));
    }

    /**
     * @notice Execute a transfer with a signed authorization; the caller MUST be the payee.
     * @dev Overload accepting EIP-1271 / EIP-2098 compact signatures.
     */
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        _receiveWithAuthorization(from, to, value, validAfter, validBefore, nonce, signature);
    }

    /**
     * @notice Cancel an existing authorization by burning its nonce.
     */
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        _cancelAuthorization(authorizer, nonce, abi.encodePacked(r, s, v));
    }

    /**
     * @notice Cancel an existing authorization, with `bytes`-encoded signature.
     */
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes calldata signature) external {
        _cancelAuthorization(authorizer, nonce, signature);
    }

    // --- ERC-165 ---

    /// @dev Magic value Circle/Centre hard-coded on USDC `FiatTokenV2_2` to advertise EIP-3009 support.
    ///      Not the strict ERC-165 XOR; we use it for ecosystem compatibility.
    bytes4 private constant _ERC3009_INTERFACE_ID = 0x7f5828d0;

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == _ERC3009_INTERFACE_ID || interfaceId == type(IERC165).interfaceId;
    }

    // --- Internal ---

    function _transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) internal {
        _requireValidAuthorization(from, nonce, validAfter, validBefore);

        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce
            )
        );
        _verifyAndMarkUsed(from, nonce, structHash, signature);

        _transfer(from, to, value);
    }

    function _receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) internal {
        if (msg.sender != to) revert ERC3009CallerNotPayee(msg.sender, to);
        _requireValidAuthorization(from, nonce, validAfter, validBefore);

        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce
            )
        );
        _verifyAndMarkUsed(from, nonce, structHash, signature);

        _transfer(from, to, value);
    }

    function _cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) internal {
        ERC3009Storage storage $ = _getERC3009Storage();
        if ($.authorizationStates[authorizer][nonce]) {
            revert ERC3009AuthorizationUsed(authorizer, nonce);
        }

        bytes32 structHash = keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce));
        bytes32 digest = _hashTypedDataV4(structHash);

        if (!SignatureChecker.isValidSignatureNow(authorizer, digest, signature)) {
            revert ERC3009InvalidSignature(authorizer);
        }

        $.authorizationStates[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    function _requireValidAuthorization(
        address authorizer,
        bytes32 nonce,
        uint256 validAfter,
        uint256 validBefore
    ) private view {
        // Strict inequalities, to match the EIP-3009 reference exactly.
        if (block.timestamp <= validAfter) revert ERC3009AuthorizationNotYetValid(validAfter);
        if (block.timestamp >= validBefore) revert ERC3009AuthorizationExpired(validBefore);
        if (_getERC3009Storage().authorizationStates[authorizer][nonce]) {
            revert ERC3009AuthorizationUsed(authorizer, nonce);
        }
    }

    function _verifyAndMarkUsed(
        address authorizer,
        bytes32 nonce,
        bytes32 structHash,
        bytes memory signature
    ) private {
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(authorizer, digest, signature)) {
            revert ERC3009InvalidSignature(authorizer);
        }
        _getERC3009Storage().authorizationStates[authorizer][nonce] = true;
        emit AuthorizationUsed(authorizer, nonce);
    }
}
