// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import '@boringcrypto/boring-solidity/contracts/BoringOwnable.sol';

import '../ILiquidationQueue.sol';
import '../../mixologist/Mixologist.sol';
import '../../swappers/MultiSwapper.sol';
import '../../swappers/CurveSwapper.sol';

import './IStableBidder.sol';

/// @notice Swaps Stable to USD0 through Curve
/// @dev Performs a swap operation between stable and USD0 through 3CRV+USD0 pool
contract ToUsdoBidder is IStableBidder, BoringOwnable {
    // ************ //
    // *** DATA *** //
    // ************ //

    // --- Public ---
    /// @notice 3Crv+USD0 swapper
    CurveSwapper public curveSwapper;

    // --- Private ---
    Mixologist _mixologist;
    YieldBox _yieldBox;
    ILiquidationQueue _liquidationQueue;
    uint256 curveAssetsLength;

    // --- Events ---
    event CurveSwapperUpdated(address indexed _old, address indexed _new);

    constructor(
        CurveSwapper curveSwapper_,
        Mixologist mixologist_,
        uint256 curvePoolAssetCount_
    ) {
        curveSwapper = curveSwapper_;

        _mixologist = mixologist_;
        _yieldBox = mixologist_.yieldBox();
        _liquidationQueue = mixologist_.liquidationQueue();

        curveAssetsLength = curvePoolAssetCount_;
    }

    // ************ //
    // *** METHODS *** //
    // ************ //
    // --- View methods ---
    /// @notice returns the unique name
    function name() external pure returns (string memory) {
        return 'stable -> USD0 (3Crv+USD0)';
    }

    /// @notice returns the swapper address who performs the first swap
    /// @dev used for sending funds to it
    function firstStepSwapper() external view returns (address) {
        return address(curveSwapper);
    }

    /// @notice returns the amount of collateral
    /// @param amountIn Stablecoin amount
    function getOutputAmount(
        uint256 stableAssetId,
        uint256 amountIn,
        bytes calldata
    ) external view returns (uint256) {
        require(
            address(_mixologist.beachBar().usdoToken()) != address(0),
            'USD0 not set'
        );

        uint256 usdoAssetId = _mixologist.beachBar().usdoAssetId();
        if (stableAssetId == usdoAssetId) {
            return amountIn;
        }

        (, address tokenInAddress, , ) = _yieldBox.assets(stableAssetId);
        (, address tokenOutAddress, , ) = _yieldBox.assets(usdoAssetId);

        uint256 tokenInCurveIndex = _getCurveIndex(tokenInAddress);
        uint256 tokenOutCurveIndex = _getCurveIndex(tokenOutAddress);
        uint256[] memory indexes = new uint256[](2);
        indexes[0] = tokenInCurveIndex;
        indexes[1] = tokenOutCurveIndex;

        uint256 share = _yieldBox.toShare(stableAssetId, amountIn, false);
        return curveSwapper.getOutputAmount(stableAssetId, indexes, share);
    }

    // --- Write methods ---
    /// @notice swaps stable to collateral
    /// @param bidder the sender to swap it from
    /// @param stableAssetId Stablecoin asset id
    /// @param amountIn Stablecoin amount
    /// @param data extra data used for the swap operation
    function swap(
        address bidder,
        uint256 stableAssetId,
        uint256 amountIn,
        bytes calldata data
    ) external returns (uint256) {
        require(msg.sender == address(_liquidationQueue), 'only LQ');
        require(
            address(_mixologist.beachBar().usdoToken()) != address(0),
            'USD0 not set'
        );
        uint256 usdoAssetId = _mixologist.beachBar().usdoAssetId();
        if (stableAssetId == usdoAssetId) {
            return amountIn;
        }

        uint256 _usdoMin = 0;
        if (data.length > 0) {
            //should always be sent
            _usdoMin = abi.decode(data, (uint256));
        }

        (, address tokenInAddress, , ) = _yieldBox.assets(stableAssetId);
        (, address tokenOutAddress, , ) = _yieldBox.assets(usdoAssetId);

        uint256 tokenInCurveIndex = _getCurveIndex(tokenInAddress);
        uint256 tokenOutCurveIndex = _getCurveIndex(tokenOutAddress);

        uint256[] memory indexes = new uint256[](2);
        indexes[0] = tokenInCurveIndex;
        indexes[1] = tokenOutCurveIndex;
        uint256 tokenInShare = _yieldBox.toShare(
            stableAssetId,
            amountIn,
            false
        );

        (, uint256 shareOut) = curveSwapper.swap(
            stableAssetId,
            usdoAssetId,
            indexes,
            tokenInShare,
            _usdoMin,
            address(_liquidationQueue)
        );

        return _yieldBox.toAmount(usdoAssetId, shareOut, false);
    }

    // --- Owner methods ---
    /// @notice sets the Curve swapper
    /// @dev used for USD0 to WETH swap
    /// @param _swapper The curve pool swapper address
    function setCurveSwapper(CurveSwapper _swapper) external onlyOwner {
        emit CurveSwapperUpdated(address(curveSwapper), address(_swapper));
        curveSwapper = _swapper;
    }

    // --- Private methods ---
    function _getCurveIndex(address token) private view returns (uint256) {
        int256 index = -1;
        for (uint256 i = 0; i < curveAssetsLength; i++) {
            address tokenAtIndex = curveSwapper.curvePool().coins(i);
            if (tokenAtIndex == token) {
                index = int256(i);
            }
        }
        require(index > -1, 'asset not found');
        return uint256(index);
    }
}
