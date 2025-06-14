pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20WrapperUpgradeable.sol";
import { ISFLUVErrors } from "./ISFLUVErrors.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract SFLUVv2 is ERC20WrapperUpgradeable, AccessControlUpgradeable, UUPSUpgradeable, ISFLUVErrors {

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
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }

    // we'll define admin roles for MINTER and REDEEMER - but not use them for now
    // this method will allow us to delegate those roles later if desired, e.g. to a dao
    function setAdminRole(bytes32 role, bytes32 adminRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
    }

    // this role allows the holder to mint (wrap) underlying token (HONEY) into SFLUV
    bytes32 public constant MINTER_ROLE = keccak256("MINTER");
    bytes32 public constant MINTER_ADMIN_ROLE = keccak256("MINTER_ADMIN");

    function depositFor(address account, uint256 amount) public override returns (bool) {
        require(hasRole(MINTER_ROLE, _msgSender()));
        return ERC20WrapperUpgradeable.depositFor(account, amount);
    }

    // this role allows the holder to redeem (unwrap) SFLUV to the underlying token (HONEY)
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER");
    bytes32 public constant REDEEMER_ADMIN_ROLE = keccak256("REDEEMER_ADMIN");

    function withdrawTo(address account, uint256 amount) public override returns (bool) {
        require(hasRole(REDEEMER_ROLE, _msgSender()));
        return ERC20WrapperUpgradeable.withdrawTo(account, amount);
    }
}
