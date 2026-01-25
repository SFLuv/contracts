pragma solidity ^0.8.26;

import "forge-std/Script.sol";
// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SFLUVZapperv1} from "../src/SFLUVZapperv1.sol";

contract GrantSFLUVZapperv1 is Script {

    // mainnet
    address constant private  SFLUV_ZAPPER_ADDR = 0xd0EBD0495750899D18b915BDeba789E2defdC394;

    // sanchez test account
    address constant private TARGET_ADDR = 0x8b631C26537a784082A55528eaD52271ce88572e;

    function run() public {
        vm.startBroadcast();
        SFLUVZapperv1 impl = SFLUVZapperv1(payable(SFLUV_ZAPPER_ADDR));
        if (!impl.hasRole(impl.REDEEMER_ADMIN_ROLE(), msg.sender)) {
            impl.grantRole(impl.REDEEMER_ADMIN_ROLE(), msg.sender);
        }
        if (!impl.hasRole(impl.REDEEMER_ROLE(), TARGET_ADDR)) {
            impl.grantRole(impl.REDEEMER_ROLE(), TARGET_ADDR);
        }
        vm.stopBroadcast();
    }
}
