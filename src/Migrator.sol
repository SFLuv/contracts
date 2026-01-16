pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20WrapperUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { SFLUVv2 } from "./SFLUVv2.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract Migrator is
  ERC20WrapperUpgradeable,
  AccessControlUpgradeable,
  UUPSUpgradeable
{
  constructor() {
    _disableInitializers();
  }

  bytes32 private constant ERC20WrapperStorageLocation = 0x3b5a617e0d4c238430871a64fe18212794b0c8d05a4eac064a8c9039fb5e0700;

  function _getERCStorage() private pure returns (ERC20WrapperStorage storage $) {
      assembly {
          $.slot := ERC20WrapperStorageLocation
      }
  }

  function migrate(address _bank, IERC20 _newUnderlying) public {
    uint256 amountOut = this.underlying().balanceOf(address(this));
    uint256 oldDecimals = 10 ** IERC20Metadata(address(this.underlying())).decimals();
    uint256 newDecimals = 10 ** IERC20Metadata(address(_newUnderlying)).decimals();
    uint256 amountIn = Math.mulDiv(amountOut, newDecimals, oldDecimals);
    if(oldDecimals > newDecimals) {
      amountIn++;
    }
    uint256 change = Math.mulDiv(amountIn, oldDecimals, newDecimals) - amountOut;


    this.underlying().transfer(_bank, amountOut);
    _newUnderlying.transferFrom(_bank, address(this), amountIn);
    _mint(_bank, change);

    ERC20WrapperStorage storage $ = _getERCStorage();
    $._underlying = _newUnderlying;
  }

  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }

}
