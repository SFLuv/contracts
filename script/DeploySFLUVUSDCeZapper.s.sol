// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SFLUVUSDCeZapper, SFLUVUSDCeZapperStorageInit} from "../src/SFLUVUSDCeZapper.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IDeployErrors} from "./IDeployErrors.sol";

contract DeploySFLUVUSDCeZapper is Script, IDeployErrors {

    function run() public {
        address honeyFactory = vm.envAddress("HONEY_FACTORY_ADDRESS");
        address sfluv = vm.envAddress("SFLUV_ADDRESS");
        address honey = vm.envAddress("HONEY_ADDRESS");
        address usdc = vm.envAddress("USDC_E_ADDRESS");
        address usdcAdapter = vm.envAddress("USDC_E_ADAPTER_ADDRESS");
        address usdcVault = vm.envAddress("USDC_E_VAULT_ADDRESS");
        address honeyToUSDCPool = vm.envAddress("HONEY_USDC_POOL_ADDRESS");
        uint32 usdcDstEid = uint32(vm.envUint("USDC_DST_EID"));

        SFLUVUSDCeZapperStorageInit memory s = SFLUVUSDCeZapperStorageInit(
            honeyFactory,
            sfluv,
            honey,
            usdc,
            usdcAdapter,
            usdcVault,
            honeyToUSDCPool,
            usdcDstEid
        );

        vm.startBroadcast();

        SFLUVv2 token = SFLUVv2(sfluv);

        bool isAdmin = token.hasRole(token.DEFAULT_ADMIN_ROLE(), msg.sender);
        if (!isAdmin) revert NotAdmin();

        bool isRedeemerAdmin = token.hasRole(token.REDEEMER_ADMIN_ROLE(), msg.sender);
        if (!isRedeemerAdmin) {
            token.grantRole(token.REDEEMER_ADMIN_ROLE(), msg.sender);
        }

        SFLUVUSDCeZapper impl = new SFLUVUSDCeZapper();

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl),
            abi.encodeCall(impl.initialize, (msg.sender, s))
        );

        token.grantRole(token.REDEEMER_ROLE(), address(proxy));

        vm.stopBroadcast();

        console.log("UUPS Proxy Address:", address(proxy));
    }
}
