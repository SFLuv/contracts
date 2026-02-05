pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SFLUVZapperv1} from "../src/SFLUVZapperv1.sol";
// import {SFLUVZapperv2} from "../src/SFLUVZapperv2.sol"; // Your new implementation
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IDeployErrors} from "./IDeployErrors.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
}

contract UpgradeSFLUVZapper is Script, IDeployErrors {

    function run() public {
        address payable proxyAddress = payable(vm.envAddress("SFLUV_ZAPPER_PROXY_ADDRESS"));

        vm.startBroadcast();

        // Get reference to the proxy (using the old interface)
        SFLUVZapperv1 proxy = SFLUVZapperv1(proxyAddress);

        // Verify caller has upgrade authority
        if (!proxy.hasRole(proxy.DEFAULT_ADMIN_ROLE(), msg.sender)) revert NotAdmin();

        // Deploy new implementation
        SFLUVZapperv1 newImpl = new SFLUVZapperv1();

        console.log("New Implementation:", address(newImpl));

        // For simple upgrade without reinitialization:
        IUUPSUpgradeable(proxyAddress).upgradeToAndCall(address(newImpl), "");

        console.log("Upgrade successful!");
        console.log("Proxy Address:", proxyAddress);

        vm.stopBroadcast();
    }
}
