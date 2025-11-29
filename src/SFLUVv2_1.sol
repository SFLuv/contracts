pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20WrapperUpgradeable.sol";
import { ISFLUVErrors } from "./ISFLUVErrors.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract SFLUVv2_1 is ERC20WrapperUpgradeable, AccessControlUpgradeable, UUPSUpgradeable, ISFLUVErrors {

    // this role allows the holder to mint (wrap) underlying token (HONEY) into SFLUV
    bytes32 public constant MINTER_ROLE = keccak256("MINTER");
    bytes32 public constant MINTER_ADMIN_ROLE = keccak256("MINTER_ADMIN");

    // this role allows the holder to redeem (unwrap) SFLUV to the underlying token (HONEY)
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER");
    bytes32 public constant REDEEMER_ADMIN_ROLE = keccak256("REDEEMER_ADMIN");

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20Wrapper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20WrapperStorageLocation = 0x3b5a617e0d4c238430871a64fe18212794b0c8d05a4eac064a8c9039fb5e0700;

    function __getERC20WrapperStorage() private pure returns (ERC20WrapperStorage storage $) {
        assembly {
            $.slot := ERC20WrapperStorageLocation
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _governance, IERC20 _underlyingToken) initializer public {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        __ERC20Wrapper_init(_underlyingToken);
        __ERC20_init("SFLUV V2.0", "SFLUV");

        // Check for zero addresses.
        if (_governance == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, _governance);

        _setRoleAdmin(MINTER_ROLE, MINTER_ADMIN_ROLE);
        _setRoleAdmin(REDEEMER_ROLE, REDEEMER_ADMIN_ROLE);

    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }

    function depositFor(address account, uint256 value) public override onlyRole(MINTER_ROLE) returns (bool) {
        ERC20WrapperStorage storage $ = __getERC20WrapperStorage();

        uint256 outAmount = value * (10 ** (this.decimals() - IERC20Metadata(address(this.underlying())).decimals()));

        address sender = _msgSender();
        if (sender == address(this)) {
            revert ERC20InvalidSender(address(this));
        }
        if (account == address(this)) {
            revert ERC20InvalidReceiver(account);
        }
        SafeERC20.safeTransferFrom($._underlying, sender, address(this), value);
        _mint(account, outAmount);
        return true;
    }

    function withdrawTo(address account, uint256 value) public override onlyRole(REDEEMER_ROLE) returns (bool) {
        ERC20WrapperStorage storage $ = __getERC20WrapperStorage();

        uint256 outAmount = value / (10 ** (this.decimals() - IERC20Metadata(address(this.underlying())).decimals())); // Solidity rounds down by default, so this should be fine

        if (account == address(this)) {
            revert ERC20InvalidReceiver(account);
        }
        _burn(_msgSender(), value);
        SafeERC20.safeTransfer($._underlying, account, outAmount);
        return true;
    }

    function decimals() public view virtual override returns (uint8) {
        return 18;
    }
}
