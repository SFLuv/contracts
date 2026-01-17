pragma solidity ^0.8.26;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20WrapperUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@berachain/contracts/honey/IHoneyFactory.sol";
import "@berachain/contracts/honey/Honey.sol";
import { IOFT, SendParam, MessagingFee, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingReceipt, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";

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
    bytes32 public constant MINTER_ROLE = keccak256("MINTER");
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER");

    /* STORAGE */

    struct SFLUVZapperStorage {
        IOFT lzbridge;
        IHoneyFactory honeyFactory;
        SFLUVv2 sfluv;
        IERC20Metadata byusd;
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
    )
        initializer
        public
    {
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
        $.lzbridge = IOFT(s.lzbridge);

        if (s.honeyFactory == address(0)) revert ZeroAddress();
        $.honeyFactory = IHoneyFactory(s.honeyFactory);

        if (s.sfluv == address(0)) revert ZeroAddress();
        $.sfluv = SFLUVv2(s.sfluv);

        if (s.byusd == address(0)) revert ZeroAddress();
        $.byusd = IERC20Metadata(s.byusd);
    }

    function zapIn(uint256 amount) external onlySFLUVRole(MINTER_ROLE) {
        _zapInTo(amount, _msgSender());
    }

    function zapInTo(uint256 amount, address to) public onlySFLUVRole(MINTER_ROLE) {
        _zapInTo(amount, to);
    }


    function zapOut(uint256 amount) external onlySFLUVRole(REDEEMER_ROLE) {
        _zapOutTo(amount, _msgSender());
    }

    function zapOutTo(uint256 amount, address to) public onlySFLUVRole(REDEEMER_ROLE) {
        _zapOutTo(amount, to);
    }

    function zapOutAndLzBridgeTo(SendParam calldata lzParam) public onlySFLUVRole(REDEEMER_ROLE) {
        SFLUVZapperStorage storage $ = _getSFLUVZapperStorage();

        uint256 zapAmount = FixedPointMathLib.mulDiv(
            lzParam.amountLD,
            10 ** $.sfluv.decimals(),
            10 ** $.byusd.decimals()
        );

        _zapOutTo(zapAmount, address(this));

        MessagingFee memory fee = $.lzbridge.quoteSend(lzParam, false);
        (
            MessagingReceipt memory mReceipt,
            OFTReceipt memory oReceipt
        ) = $.lzbridge.send(
            lzParam,
            fee,
            address(this)
        );
    }

    /* INTERNAL */


    function _zapInTo(uint256 amount, address to) private {
        SFLUVZapperStorage storage $ = _getSFLUVZapperStorage();

        bool success = $.byusd.transferFrom(
            _msgSender(),
            address(this),
            amount
        );
        if (!success) revert TransferFailed(address($.byusd), address(this), _msgSender(), amount);

        uint256 honeyAmount = $.honeyFactory.mint(
            address($.byusd),
            amount,
            address(this),
            false
        );

        success = $.sfluv.depositFor(to, honeyAmount);
        if (!success) revert MintFailed();
    }

    function _zapOutTo(uint256 amount, address to) private {
        SFLUVZapperStorage storage $ = _getSFLUVZapperStorage();

        bool success = $.sfluv.transferFrom(
            _msgSender(),
            address(this),
            amount
        );
        if (!success) revert TransferFailed(address($.sfluv), address(this), _msgSender(), amount);

        success = $.sfluv.withdrawTo(address(this), amount);
        if (!success) revert RedeemFailed();

        $.honeyFactory.redeem(
            address($.byusd),
            amount,
            to,
            false
        );
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
