pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20WrapperUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "@berachain/contracts/honey/IHoneyFactory.sol";

import "./ISFLUVZapperErrors.sol";
import "./SFLUVv2.sol";

struct SFLUVZapperStorageInit {
  address lzbridge;
  address honeyFactory;
  address sfluv;
  address byusd;
}

contract SFLUVZapperv1 is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ISFLUVZapperErrors
{
    /* STORAGE */

    struct SFLUVZapperStorage {
        address lzbridge;
        IHoneyFactory honeyFactory;
        SFLUVv2 sfluv;
        IERC20 byusd;
    }

    // keccak256(abi.encode(uint256(keccak256("SFLUV.storage.SFLUVZapper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SFLUVZapperStorageLocation =
        0x4387e05f939ab688c86fd2a91847d45cedf6bd707f41c3ea87ea7383b559aa00;

    function _getSFLUVZapperStorage()
        private
        pure
        returns (SFLUVZapperStorage storage $)
    {
        assembly {
            $.slot := SFLUVZapperStorageLocation
        }
    }

    modifier onlySFLUVRole(bytes32 role) {
        SFLUVZapperStorage storage $ = _getSFLUVZapperStorage();

        if (!$.sfluv.hasRole(role, _msgSender()))
            revert AccessControlUnauthorizedAccount(_msgSender(), role);
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _governance,
        SFLUVZapperStorageInit calldata _storage
    ) public {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Storage_init(_storage);

        _grantRole(DEFAULT_ADMIN_ROLE, _governance);
    }

    function __Storage_init(
        SFLUVZapperStorageInit calldata s
    ) internal onlyInitializing {
        SFLUVZapperStorage storage $ = _getSFLUVZapperStorage();

        if (s.lzbridge == address(0)) revert ZeroAddress();
        $.lzbridge = s.lzbridge;

        if (s.honeyFactory == address(0)) revert ZeroAddress();
        $.honeyFactory = IHoneyFactory(s.honeyFactory);

        if (s.sfluv == address(0)) revert ZeroAddress();
        $.sfluv = SFLUVv2(s.sfluv);

        if (s.byusd == address(0)) revert ZeroAddress();
        $.byusd = IERC20(s.byusd);
    }

    function zapIn(uint256 amount) external {}

    function zapInTo(uint256 amount, address to) public {}

    function zapOut(uint256 amount) external {}

    function zapOutTo(uint256 amount, address to) public {}

    function zapOutAndLzBridgeTo(uint256 amount, address to) public {}

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}
}