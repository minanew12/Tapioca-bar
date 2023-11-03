// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

//interfaces
import {ITapiocaOFTBase} from "tapioca-periph/contracts/interfaces/ITapiocaOFT.sol";
import "tapioca-periph/contracts/interfaces/IGmxExchangeRouter.sol";

import "./BaseLeverageExecutor.sol";

contract AssetToGmxEthUsdcLpLeverageExecutor is BaseLeverageExecutor {
    IERC20 public immutable usdc; //0xaf88d065e77c8cC2239327C5EDb3A432268e5831
    IERC20 public immutable weth; //0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
    address public immutable gmMarket; //0x70d95587d40A2caf56bd97485aB3Eec10Bee6336
    address public immutable router; //0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6
    IGmxExchangeRouter public immutable exchangeRouter; //0x7c68c7866a64fa2160f78eeae12217ffbf871fa8
    address public immutable withdrawalVault; //0x0628d46b5d145f183adb6ef1f2c97ed1c4701c55

    uint256 private constant _FEE = 748000000000000;

    constructor(
        YieldBox _yb,
        ISwapper _swapper,
        ICluster _cluster,
        IERC20 _usdc,
        IERC20 _weth,
        address _router,
        IGmxExchangeRouter _exchangeRouter,
        address _gmMarket,
        address _withdrawalVault
    ) BaseLeverageExecutor(_yb, _swapper, _cluster) {
        usdc = _usdc;
        weth = _weth;
        router = _router;
        exchangeRouter = _exchangeRouter;
        gmMarket = _gmMarket;
        withdrawalVault = _withdrawalVault;
    }

    // ********************* //
    // *** PUBLIC MEHODS *** //
    // ********************* //
    /// @notice buys collateral with asset
    /// @dev USDO > USDC > GMX-ETH-USDC LP > wrap
    /// 'data' param needs the following `(uint256, bytes, uint256)`
    ///      - min USDC amount (for swapping Asset with USDC), dexUsdcData (for swapping Asset with USDC; it can be empty), lpMinAmountOut (GM LP minimum amout to obtain when staking USDC)
    ///      - lpMinAmountOut can be obtained by querying `gmMarket`
    /// @param collateralId Collateral's YieldBox id
    /// @param assetAddress usually USDO address
    /// @param collateralAddress tLP address (TOFT GMX-ETH-USDC LP)
    /// @param assetAmountIn amount to swap
    /// @param from collateral receiver
    /// @param data AssetToGmxEthUsdcLpLeverageExecutor data
    function getCollateral(
        uint256 collateralId,
        address assetAddress,
        address collateralAddress,
        uint256 assetAmountIn,
        address from,
        bytes calldata data
    ) external override returns (uint256 collateralAmountOut) {
        _assureSwapperValidity();

        //decode data
        (
            uint256 minUsdcAmountOut,
            bytes memory dexUsdcData,
            uint256 lpMinAmountOut
        ) = abi.decode(data, (uint256, bytes, uint256));

        //swap Asset with USDC
        uint256 usdcAmount = _swapTokens(
            assetAddress,
            address(usdc),
            assetAmountIn,
            minUsdcAmountOut,
            dexUsdcData
        );
        require(
            usdcAmount >= minUsdcAmountOut,
            "AssetToGmxEthUsdcLpLeverageExecutor: not enough USDC"
        );

        //get GMX-ETH-USDC LP address
        address lpAddress = ITapiocaOFTBase(collateralAddress).erc20();
        require(
            lpAddress != address(0),
            "AssetToGmxEthUsdcLpLeverageExecutor: LP not valid"
        );

        //stake USDC and get GMX-ETH-USDC LP
        collateralAmountOut = _stakeUsdc(
            usdcAmount,
            lpMinAmountOut,
            address(weth),
            address(usdc),
            lpAddress
        );

        //wrap into tLP
        IERC20(lpAddress).approve(collateralAddress, 0);
        IERC20(lpAddress).approve(collateralAddress, collateralAmountOut);
        ITapiocaOFTBase(collateralAddress).wrap(
            address(this),
            address(this),
            collateralAmountOut
        );

        //deposit tGLP to YieldBox
        IERC20(collateralAddress).approve(address(yieldBox), 0);
        IERC20(collateralAddress).approve(
            address(yieldBox),
            collateralAmountOut
        );
        yieldBox.depositAsset(
            collateralId,
            address(this),
            from,
            collateralAmountOut,
            0
        );
    }

    /// @notice buys asset with collateral
    /// @dev unwrap tLP > USDC > Asset
    /// `data` param needs the following `(uint256, bytes, uint256, uint256, uint256)`
    ///     - minAssetAmountOut & dexAssetData (for swapping USDC to Asset)
    ///     - minWethAmount & minUsdcAmount (for unstaking GM LP; it can be queried )
    ///     - minWethToUsdcAmount & dexWethToUsdcData (for swapping WETH to USDC)
    /// @param assetId Asset's YieldBox id; usually USDO asset id
    /// @param collateralAddress tLP address (TOFT GMX-ETH-USDC LP)
    /// @param assetAddress usually USDO address
    /// @param collateralAmountIn amount to swap
    /// @param from collateral receiver
    /// @param data AssetToGmxEthUsdcLpLeverageExecutor data
    function getAsset(
        uint256 assetId,
        address collateralAddress,
        address assetAddress,
        uint256 collateralAmountIn,
        address from,
        bytes calldata data
    ) external override returns (uint256 assetAmountOut) {
        _assureSwapperValidity();

        //decode data
        (
            uint256 minAssetAmountOut,
            bytes memory dexAssetData,
            uint256 minWethAmount,
            uint256 minUsdcAmount,
            uint256 minWethToUsdcAmount,
            bytes memory dexWethToUsdcData
        ) = abi.decode(
                data,
                (uint256, bytes, uint256, uint256, uint256, bytes)
            );

        address lpAddress = ITapiocaOFTBase(collateralAddress).erc20();
        require(
            lpAddress != address(0),
            "AssetToGmxEthUsdcLpLeverageExecutor: LP not valid"
        );

        ITapiocaOFTBase(collateralAddress).unwrap(
            address(this),
            collateralAmountIn
        );

        //unstake GMX-ETH-USDC LP and get USDC
        (uint256 usdcAmount, uint256 wethAmount) = _unstakeLp(
            collateralAmountIn,
            lpAddress,
            minWethAmount,
            minUsdcAmount
        );

        //swap WETH with USDC
        uint256 obtainedUsdc = _swapTokens(
            address(weth),
            address(usdc),
            wethAmount,
            minWethToUsdcAmount,
            dexWethToUsdcData
        );

        //swap USDC with Asset
        assetAmountOut = _swapTokens(
            address(usdc),
            assetAddress,
            usdcAmount + obtainedUsdc,
            minAssetAmountOut,
            dexAssetData
        );
        require(
            assetAmountOut >= minAssetAmountOut,
            "AssetToGmxEthUsdcLpLeverageExecutor: not enough Asset"
        );

        IERC20(assetAddress).approve(address(yieldBox), 0);
        IERC20(assetAddress).approve(address(yieldBox), assetAmountOut);
        yieldBox.depositAsset(assetId, address(this), from, assetAmountOut, 0);
    }

    // ********************** //
    // *** PRIVATE MEHODS *** //
    // ********************** //
    /// @dev add liquidity to GMX market
    function _stakeUsdc(
        uint256 usdcAmount,
        uint256 lpMinAmount,
        address longToken,
        address shortToken,
        address lp
    ) private returns (uint256 collateralAmountOut) {
        bytes[] memory data = new bytes[](3);

        //create sendWnt
        data[0] = abi.encodeWithSelector(
            IGmxExchangeRouter.sendWnt.selector,
            address(this),
            _FEE //this seems to be hardcoded
        );

        //create sendTokens
        data[1] = abi.encodeWithSelector(
            IGmxExchangeRouter.sendTokens.selector,
            usdc,
            address(this), //TODO: check this
            usdcAmount
        );

        //create createDeposit
        address[] memory emptyPath = new address[](0);
        IGmxExchangeRouter.CreateDepositParams
            memory createDepositParams = IGmxExchangeRouter
                .CreateDepositParams({
                    receiver: address(this),
                    callbackContract: address(0),
                    uiFeeReceiver: address(0),
                    market: gmMarket,
                    initialLongToken: longToken,
                    initialShortToken: shortToken,
                    longTokenSwapPath: emptyPath,
                    shortTokenSwapPath: emptyPath,
                    minMarketTokens: lpMinAmount,
                    shouldUnwrapNativeToken: false,
                    executionFee: _FEE, //this seems to be hardcoded
                    callbackGasLimit: 0
                });
        data[2] = abi.encodeWithSelector(
            IGmxExchangeRouter.createDeposit.selector,
            createDepositParams
        );

        //execute multicall
        uint256 lpBalanceBefore = IERC20(lp).balanceOf(address(this));
        usdc.approve(router, 0);
        usdc.approve(router, usdcAmount);
        exchangeRouter.multicall(data);
        collateralAmountOut =
            IERC20(lp).balanceOf(address(this)) -
            lpBalanceBefore;
        require(
            collateralAmountOut > 0,
            "AssetToGmxEthUsdcLpLeverageExecutor: multicall failed"
        );
    }

    /// @dev remove liquidity from GMX market
    ///     - it will return both USDC and WETH
    function _unstakeLp(
        uint256 lpAmount,
        address lpAddress,
        uint256 minWethAmount,
        uint256 minUsdcAmount
    ) private returns (uint256 usdcAmount, uint256 wethAmount) {
        bytes[] memory data = new bytes[](3);

        //create sendWnt
        data[0] = abi.encodeWithSelector(
            IGmxExchangeRouter.sendWnt.selector,
            withdrawalVault,
            _FEE //this seems to be hardcoded
        );

        //create sendTokens
        data[1] = abi.encodeWithSelector(
            IGmxExchangeRouter.sendTokens.selector,
            lpAddress,
            withdrawalVault,
            lpAmount
        );

        //create createWithdrawal
        address[] memory emptyPath = new address[](0);
        IGmxExchangeRouter.CreateWithdrawalParams
            memory createWithdrawalParams = IGmxExchangeRouter
                .CreateWithdrawalParams({
                    receiver: address(this),
                    callbackContract: address(0),
                    uiFeeReceiver: address(0),
                    market: gmMarket,
                    longTokenSwapPath: emptyPath,
                    shortTokenSwapPath: emptyPath,
                    minLongTokenAmount: minWethAmount,
                    minShortTokenAmount: minUsdcAmount,
                    shouldUnwrapNativeToken: true,
                    executionFee: _FEE, //this seems to be hardcoded
                    callbackGasLimit: 0
                });
        data[2] = abi.encodeWithSelector(
            IGmxExchangeRouter.createWithdrawal.selector,
            createWithdrawalParams
        );

        //execute multicall
        IERC20(lpAddress).approve(router, 0);
        IERC20(lpAddress).approve(router, lpAmount);

        uint256 usdcBalanceBefore = usdc.balanceOf(address(this));
        uint256 wethBalanceBefore = weth.balanceOf(address(this));
        exchangeRouter.multicall(data);
        usdcAmount = usdc.balanceOf(address(this)) - usdcBalanceBefore;
        wethAmount = weth.balanceOf(address(this)) - wethBalanceBefore;
    }
}
