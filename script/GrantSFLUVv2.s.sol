pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract GrantSFLUVv2 is Script {

    // mainnet
    address constant private SFLUV_V2_ADDR = 0x881cAd4f885c6701D8481c0eD347f6d35444eA7e;

    // mainnet gov account
    address constant private TARGET_ADDR = 0x90496e23825aD0C8107d04671e6a27f30630Fc35;

    function run() public {
        vm.startBroadcast();
        SFLUVv2 impl = SFLUVv2(SFLUV_V2_ADDR);
        impl.grantRole(impl.MINTER_ADMIN_ROLE(), TARGET_ADDR);
        vm.stopBroadcast();
    }
}