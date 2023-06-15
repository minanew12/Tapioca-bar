// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

//LZ
import "tapioca-sdk/dist/contracts/token/oft/v2/OFTV2.sol";

//OZ
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";

//TAPIOCA
import "tapioca-periph/contracts/interfaces/IYieldBoxBase.sol";
import {IUSDOBase} from "tapioca-periph/contracts/interfaces/IUSDO.sol";

contract BaseUSDOStorage is OFTV2 {
    /// @notice the YieldBox address.
    IYieldBoxBase public immutable yieldBox;

    /// @notice returns the Conservator address
    address public conservator;
    /// @notice addresses allowed to mint USDO
    /// @dev chainId>address>status
    mapping(uint256 => mapping(address => bool)) public allowedMinter;
    /// @notice addresses allowed to burn USDO
    /// @dev chainId>address>status
    mapping(uint256 => mapping(address => bool)) public allowedBurner;
    /// @notice returns the pause state of the contract
    bool public paused;

    /// @notice returns the flash mint fee
    uint256 public flashMintFee;
    /// @notice returns the maximum amount of USDO that can be minted through the EIP-3156 flow
    uint256 public maxFlashMint;

    uint256 internal constant FLASH_MINT_FEE_PRECISION = 1e6;
    bytes32 internal constant FLASH_MINT_CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    uint16 internal constant PT_MARKET_REMOVE_ASSET = 773;
    uint16 internal constant PT_YB_SEND_SGL_LEND_OR_REPAY = 774;
    uint16 internal constant PT_LEVERAGE_MARKET_UP = 775;

    // ************** //
    // *** EVENTS *** //
    // ************** //
    /// @notice event emitted when USDO is minted
    event Minted(address indexed _for, uint256 _amount);
    /// @notice event emitted when USDO is burned
    event Burned(address indexed _from, uint256 _amount);
    /// @notice event emitted when a new address is set or removed from minters array
    event SetMinterStatus(address indexed _for, bool _status);
    /// @notice event emitted when a new address is set or removed from burners array
    event SetBurnerStatus(address indexed _for, bool _status);
    /// @notice event emitted when conservator address is updated
    event ConservatorUpdated(address indexed old, address indexed _new);
    /// @notice event emitted when pause state is updated
    event PausedUpdated(bool oldState, bool newState);
    /// @notice event emitted when flash mint fee is updated
    event FlashMintFeeUpdated(uint256 _old, uint256 _new);
    /// @notice event emitted when max flash mintable amount is updated
    event MaxFlashMintUpdated(uint256 _old, uint256 _new);

    receive() external payable {}

    constructor(
        address _lzEndpoint,
        IYieldBoxBase _yieldBox
    ) OFTV2("USDO", "USDO", 8, _lzEndpoint) {
        uint256 chain = _getChainId();
        allowedMinter[chain][msg.sender] = true;
        allowedBurner[chain][msg.sender] = true;
        flashMintFee = 10; // 0.001%
        maxFlashMint = 100_000 * 1e18; // 100k USDO

        yieldBox = _yieldBox;
    }

    function _getChainId() internal view returns (uint256) {
        return ILayerZeroEndpoint(lzEndpoint).getChainId();
    }
}