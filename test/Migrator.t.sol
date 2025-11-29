pragma solidity ^0.8.26;

import {SFLUVv2} from "../src/SFLUVv2.sol";
import {SFLUVv2_1} from "../src/SFLUVv2_1.sol";
import {Migrator} from "../src/Migrator.sol";
import "../src/MockCoin.sol";
import {Test} from "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract MigratorTest is
  Test
{
  function setUp() public {
    string memory forkURL = vm.envString('FORK_URL');
    uint256 forkBlock = vm.envUint('FORK_BLOCK');

    vm.createSelectFork(forkURL, forkBlock);
  }

  function testMigrate() public {
    address proxyAddress = vm.envAddress("SFLUV_ADDRESS");
    address byusd = vm.envAddress("BYUSD_ADDRESS");

    Migrator _migrator = new Migrator();
    SFLUVv2_1 _newImpl = new SFLUVv2_1();
    UUPSUpgradeable proxy = UUPSUpgradeable(proxyAddress);

    address bank = 0x719C4260007fd0eA3d1ea1BeE07B9c0ba9535eed; // random high byusd balance address
    IERC20 newUnderlying = IERC20(byusd);
    IERC20 oldUnderlying = SFLUVv2(proxyAddress).underlying();

    console.log("PRE MIGRATION:");
    console.log("  BANK:");
    console.log("    SFLUV:", SFLUVv2(proxyAddress).balanceOf(bank));
    console.log("    OLD UNDERLYING:", oldUnderlying.balanceOf(bank));
    console.log("    NEW UNDERLYING:", newUnderlying.balanceOf(bank));
    console.log("  PROXY:");
    console.log("    SFLUV:", SFLUVv2(proxyAddress).balanceOf(address(proxy)));
    console.log("    OLD UNDERLYING:", oldUnderlying.balanceOf(address(proxy)));
    console.log("    NEW UNDERLYING:", newUnderlying.balanceOf(address(proxy)));


    vm.startPrank(bank);

    uint256 amountIn = Math.mulDiv(
      oldUnderlying.balanceOf(address(proxy)),
      IERC20Metadata(address(newUnderlying)).decimals(),
      IERC20Metadata(address(oldUnderlying)).decimals()
    );
    if(IERC20Metadata(address(oldUnderlying)).decimals() > IERC20Metadata(address(newUnderlying)).decimals()) {
      amountIn++;
    }
    newUnderlying.approve(address(proxy), amountIn);

    vm.stopPrank();


    assertEq(address(SFLUVv2(proxyAddress).underlying()), address(oldUnderlying));


    address admin = 0x90496e23825aD0C8107d04671e6a27f30630Fc35;
    vm.startPrank(admin);

    proxy.upgradeToAndCall(address(_migrator), abi.encodeCall(
      _migrator.migrate,
      (bank, IERC20(address(newUnderlying)))
    ));
    console.log("UNDERLYING:", address(SFLUVv2(address(proxy)).underlying()));
    proxy.upgradeToAndCall(address(_newImpl), abi.encode());



    console.log("POST MIGRATION:");
    console.log("  BANK:");
    console.log("    SFLUV:", SFLUVv2(proxyAddress).balanceOf(bank));
    console.log("    OLD UNDERLYING:", oldUnderlying.balanceOf(bank));
    console.log("    NEW UNDERLYING:", newUnderlying.balanceOf(bank));
    console.log("  PROXY:");
    console.log("    SFLUV:", SFLUVv2(proxyAddress).balanceOf(address(proxy)));
    console.log("    OLD UNDERLYING:", oldUnderlying.balanceOf(address(proxy)));
    console.log("    NEW UNDERLYING:", newUnderlying.balanceOf(address(proxy)));

    assertEq(address(SFLUVv2(proxyAddress).underlying()), address(newUnderlying));

    SFLUVv2(proxyAddress).grantRole(SFLUVv2(proxyAddress).REDEEMER_ADMIN_ROLE(), admin);
    SFLUVv2(proxyAddress).grantRole(SFLUVv2(proxyAddress).REDEEMER_ROLE(), bank);

    vm.stopPrank();


    vm.startPrank(bank);

    SFLUVv2(proxyAddress).withdrawTo(bank, SFLUVv2(proxyAddress).balanceOf(bank));
    console.log("POST UNWRAP:");
    console.log("  BANK:");
    console.log("    SFLUV:", SFLUVv2(proxyAddress).balanceOf(address(bank)));
    console.log("    NEW UNDERLYING:", newUnderlying.balanceOf(address(bank)));

    vm.stopPrank();
  }
}