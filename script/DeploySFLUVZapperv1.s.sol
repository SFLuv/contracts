pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SFLUVZapperv1, SFLUVZapperStorageInit} from "../src/SFLUVZapperv1.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDeployErrors} from "./IDeployErrors.sol";

contract DeploySFLUVZapperv1 is Script, IDeployErrors {

    function run() public {
        address honeyFactory = vm.envAddress("HONEY_FACTORY_ADDRESS");
        address sfluv = vm.envAddress("SFLUV_ADDRESS");
        address byusd = vm.envAddress("BYUSD_ADDRESS");
        address honey = vm.envAddress("HONEY_ADDRESS");
        address honeyToBYUSDPool = vm.envAddress("HONEY_BYUSD_POOL_ADDRESS");
        address byusdVault = vm.envAddress("BYUSD_VAULT_ADDRESS");


        SFLUVZapperStorageInit memory s = SFLUVZapperStorageInit(
            honeyFactory,
            sfluv,
            byusd,
            honey,
            honeyToBYUSDPool,
            byusdVault
        );

        vm.startBroadcast();

        SFLUVv2 token = SFLUVv2(sfluv);

        bool isAdmin = token.hasRole(token.DEFAULT_ADMIN_ROLE(), msg.sender);
        if (!isAdmin) revert NotAdmin();

        bool isMinterAdmin = token.hasRole(token.MINTER_ADMIN_ROLE(), msg.sender);
        require(isMinterAdmin);
        bool isRedeemerAdmin = token.hasRole(token.REDEEMER_ADMIN_ROLE(), msg.sender);
        require(isRedeemerAdmin);

        SFLUVZapperv1 impl = new SFLUVZapperv1();

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl),
            abi.encodeCall(impl.initialize, (msg.sender, s)));

        token.grantRole(token.MINTER_ROLE(), address(proxy));
        token.grantRole(token.REDEEMER_ROLE(), address(proxy));

        vm.stopBroadcast();

        console.log("UUPS Proxy Address:", address(proxy));
    }
}
