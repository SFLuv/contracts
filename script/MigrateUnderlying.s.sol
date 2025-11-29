pragma solidity ^0.8.26;

import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Migrator} from "../src/Migrator.sol";
import "forge-std/Script.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MigrateUnderlying is
  Script
{
  function run() public {
    address proxyContract = payable(vm.envAddress("SFLUV_ADDRESS"));
    address newUnderlying = vm.envAddress("PYUSD_ADDRESS");
    address oldUnderlying = vm.envAddress("HONEY_ADDRESS");

    vm.startBroadcast();

    Migrator _migrator = new Migrator();
    SFLUVv2 _newImpl = new SFLUVv2();
    UUPSUpgradeable proxy = UUPSUpgradeable(proxyContract);


    proxy.upgradeToAndCall(address(_migrator), abi.encodeCall(
      _migrator.migrate,
      (msg.sender, IERC20(newUnderlying))
    ));
    proxy.upgradeToAndCall(address(_newImpl), abi.encode());


    vm.stopBroadcast();
  }
}