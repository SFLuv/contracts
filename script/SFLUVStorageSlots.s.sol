// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

contract SFLUVStorageSlotScript is Script {
    function setUp() public {}

    function run() public pure {
        bytes32 SFLUVZapperStorage =
            keccak256(abi.encode(uint256(keccak256("SFLUV.storage.SFLUVZapper")) - 1)) & ~bytes32(uint256(0xff));

        console.log("SFLUVZapper Storage:         ", vm.toString(SFLUVZapperStorage));
    }
}
