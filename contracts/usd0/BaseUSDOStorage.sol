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
import "tapioca-periph/contracts/interfaces/ICluster.sol";

contract BaseUSDOStorage is OFTV2 {
    /// @notice the YieldBox address.
    IYieldBoxBase public immutable yieldBox;
    /// @notice The Cluster address
    ICluster public cluster;
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

    enum Module {
        NonModule, //0
        Generic,
        Leverage,
        LeverageDestination,
        Market,
        MarketDestination,
        Options,
        OptionsDestination
    }

    /// @notice returns whitelisted modules
    mapping(Module module => address moduleAddress) internal _moduleAddresses;

    uint16 internal constant PT_MARKET_REMOVE_ASSET = 773;
    uint16 internal constant PT_YB_SEND_SGL_LEND_OR_REPAY = 774;
    uint16 internal constant PT_LEVERAGE_MARKET_UP = 775;
    uint16 internal constant PT_TAP_EXERCISE = 777;
    uint16 internal constant PT_SEND_FROM = 778;
    uint16 internal constant PT_APPROVE = 779;

    uint256 internal constant SWAP_MAX_SLIPPAGE = 500; //5%
    uint256 internal constant SLIPPAGE_PRECISION = 1e4;

    // ************** //
    // *** EVENTS *** //
    // ************** //
    /// @notice event emitted when a new address is set or removed from minters array
    event SetMinterStatus(address indexed _for, bool _status);
    /// @notice event emitted when a new address is set or removed from burners array
    event SetBurnerStatus(address indexed _for, bool _status);
    /// @notice event emitted when pause state is updated
    event PausedUpdated(bool oldState, bool newState);

    receive() external payable {}

    constructor(
        address _lzEndpoint,
        IYieldBoxBase _yieldBox,
        ICluster _cluster
    ) OFTV2("USDO", "USDO", 8, _lzEndpoint) {
        uint256 chain = _getChainId();
        allowedMinter[chain][msg.sender] = true;
        allowedBurner[chain][msg.sender] = true;

        yieldBox = _yieldBox;
        cluster = _cluster;
    }

    function _getChainId() internal view returns (uint256) {
        return ILayerZeroEndpoint(lzEndpoint).getChainId();
    }

    function _getRevertMsg(
        bytes memory _returnData
    ) internal pure returns (string memory) {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (_returnData.length < 68) return "USDO: data";
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string)); // All that remains is the revert string
    }
}
