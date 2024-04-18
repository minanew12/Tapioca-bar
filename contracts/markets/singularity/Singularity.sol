// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.22;

// External
import {RebaseLibrary, Rebase} from "@boringcrypto/boring-solidity/contracts/libraries/BoringRebase.sol";
import {IERC20} from "@boringcrypto/boring-solidity/contracts/libraries/BoringERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// Tapioca
import {ILeverageExecutor} from "tapioca-periph/interfaces/bar/ILeverageExecutor.sol";
import {ITapiocaOracle} from "tapioca-periph/interfaces/periph/ITapiocaOracle.sol";
import {IYieldBox} from "tapioca-periph/interfaces/yieldbox/IYieldBox.sol";
import {IPearlmit} from "tapioca-periph/interfaces/periph/IPearlmit.sol";
import {IPenrose} from "tapioca-periph/interfaces/bar/IPenrose.sol";
import {Module} from "tapioca-periph/interfaces/bar/IMarket.sol";
import {MarketStateView} from "../MarketStateView.sol";
import {SGLLiquidation} from "./SGLLiquidation.sol";
import {SGLCollateral} from "./SGLCollateral.sol";
import {MarketERC20} from "../MarketERC20.sol";
import {SGLLeverage} from "./SGLLeverage.sol";
import {SGLStorage} from "./SGLStorage.sol";
import {SGLCommon} from "./SGLCommon.sol";
import {SGLBorrow} from "./SGLBorrow.sol";

// solhint-disable max-line-length

/*

████████╗ █████╗ ██████╗ ██╗ ██████╗  ██████╗ █████╗ 
╚══██╔══╝██╔══██╗██╔══██╗██║██╔═══██╗██╔════╝██╔══██╗
   ██║   ███████║██████╔╝██║██║   ██║██║     ███████║
   ██║   ██╔══██║██╔═══╝ ██║██║   ██║██║     ██╔══██║
   ██║   ██║  ██║██║     ██║╚██████╔╝╚██████╗██║  ██║
   ╚═╝   ╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝
   
*/

/// @title Tapioca market
contract Singularity is MarketStateView, SGLCommon {
    using RebaseLibrary for Rebase;
    using SafeCast for uint256;

    // ************ //
    // *** VARS *** //
    // ************ //
    /// @notice returns the liquidation module
    SGLLiquidation public liquidationModule;
    /// @notice returns the borrow module
    SGLBorrow public borrowModule;
    /// @notice returns the collateral module
    SGLCollateral public collateralModule;
    /// @notice returns the leverage module
    SGLLeverage public leverageModule;

    // ************** //
    // *** ERRORS *** //
    // ************** //
    error BadPair();
    error NotValid();
    error ModuleNotSet();
    error NotAuthorized();
    error SameState();

    struct _InitMemoryData {
        IPenrose penrose_;
        ITapiocaOracle _oracle;
        uint256 _exchangeRatePrecision;
        uint256 _collateralizationRate;
        uint256 _liquidationCollateralizationRate;
        ILeverageExecutor _leverageExecutor;
    }

    struct _InitMemoryModulesData {
        address _liquidationModule;
        address _borrowModule;
        address _collateralModule;
        address _leverageModule;
    }

    struct _InitMemoryTokensData {
        IERC20 _asset;
        uint256 _assetId;
        IERC20 _collateral;
        uint256 _collateralId;
    }

    function totalSupply() public view override(MarketERC20, SGLStorage) returns (uint256) {
        return totalAsset.base;
    }

    /// @notice The init function that acts as a constructor
    function init(bytes calldata initData) external onlyOnce {
        (
            _InitMemoryModulesData memory _initMemoryModulesData,
            _InitMemoryTokensData memory _initMemoryTokensData,
            _InitMemoryData memory _initMemoryData
        ) = abi.decode(initData, (_InitMemoryModulesData, _InitMemoryTokensData, _InitMemoryData));

        penrose = _initMemoryData.penrose_;
        pearlmit = IPearlmit(_initMemoryData.penrose_.pearlmit());
        yieldBox = IYieldBox(_initMemoryData.penrose_.yieldBox());
        _transferOwnership(address(penrose));

        if (address(_initMemoryTokensData._collateral) == address(0)) {
            revert BadPair();
        }
        if (address(_initMemoryTokensData._asset) == address(0)) {
            revert BadPair();
        }
        if (address(_initMemoryData._oracle) == address(0)) revert BadPair();

        _initModules(
            _initMemoryModulesData._liquidationModule,
            _initMemoryModulesData._borrowModule,
            _initMemoryModulesData._collateralModule,
            _initMemoryModulesData._leverageModule
        );
        _initCoreStorage(
            _initMemoryTokensData._asset,
            _initMemoryTokensData._assetId,
            _initMemoryTokensData._collateral,
            _initMemoryTokensData._collateralId,
            _initMemoryData._oracle,
            _initMemoryData._leverageExecutor
        );
        _initDefaultValues(
            _initMemoryData._collateralizationRate,
            _initMemoryData._liquidationCollateralizationRate,
            _initMemoryData._exchangeRatePrecision
        );
    }

    function _initModules(
        address _liquidationModule,
        address _borrowModule,
        address _collateralModule,
        address _leverageModule
    ) private {
        if (_liquidationModule == address(0)) revert NotValid();
        if (_collateralModule == address(0)) revert NotValid();
        if (_borrowModule == address(0)) revert NotValid();
        if (_leverageModule == address(0)) revert NotValid();
        liquidationModule = SGLLiquidation(_liquidationModule);
        collateralModule = SGLCollateral(_collateralModule);
        borrowModule = SGLBorrow(_borrowModule);
        leverageModule = SGLLeverage(_leverageModule);
    }

    function _initCoreStorage(
        IERC20 _asset,
        uint256 _assetId,
        IERC20 _collateral,
        uint256 _collateralId,
        ITapiocaOracle _oracle,
        ILeverageExecutor _leverageExecutor
    ) private {
        asset = _asset;
        collateral = _collateral;
        assetId = _assetId;
        collateralId = _collateralId;
        oracle = _oracle;
        leverageExecutor = _leverageExecutor;
    }

    function _initDefaultValues(
        uint256 _collateralizationRate,
        uint256 _liquidationCollateralizationRate,
        uint256 _exchangeRatePrecision
    ) private {
        collateralizationRate = _collateralizationRate > 0 ? _collateralizationRate : 75000;
        liquidationCollateralizationRate =
            _liquidationCollateralizationRate > 0 ? _liquidationCollateralizationRate : 80000;
        require(
            liquidationCollateralizationRate > collateralizationRate, "SGL: liquidationCollateralizationRate not valid"
        );
        minimumInterestPerSecond = 158548960; // approx 0.5% APR
        maximumInterestPerSecond = 317097920000; // approx 1000% APR
        interestElasticity = 28800e36; // Half or double in 28800 seconds (8 hours) if linear
        startingInterestPerSecond = minimumInterestPerSecond;
        accrueInfo.interestPerSecond = startingInterestPerSecond; // 1% APR, with 1e18 being 100%
        updateExchangeRate();
        //default fees
        protocolFee = 10000; // 10%; used for accrual
        borrowOpeningFee = 50; // 0.05%
        //liquidation
        liquidationMultiplier = 12000; //12%
        lqCollateralizationRate = 25000;
        EXCHANGE_RATE_PRECISION = _exchangeRatePrecision > 0 ? _exchangeRatePrecision : 1e18;
        minLiquidatorReward = 8e4;
        maxLiquidatorReward = 9e4;
        liquidationBonusAmount = 1e4;
        minimumTargetUtilization = 3e17;
        maximumTargetUtilization = 5e17;
        fullUtilizationMinusMax = FULL_UTILIZATION - maximumTargetUtilization;
        rateValidDuration = 24 hours;

        conservator = owner();
    }

    // ************************ //
    // *** PUBLIC FUNCTIONS *** //
    // ************************ //

    /// @notice Allows batched call to Singularity.
    /// @param calls An array encoded call data.
    /// @param revertOnFail If True then reverts after a failed call and stops doing further calls.
    /// @return successes count of successful operations
    /// @return results array of revert messages
    function execute(Module[] calldata modules, bytes[] calldata calls, bool revertOnFail)
        external
        nonReentrant
        returns (bool[] memory successes, bytes[] memory results)
    {
        successes = new bool[](calls.length);
        results = new bytes[](calls.length);
        if (modules.length != calls.length) revert NotValid();
        unchecked {
            for (uint256 i; i < calls.length; i++) {
                (bool success, bytes memory result) = _extractModule(modules[i]).delegatecall(calls[i]);

                if (!success && revertOnFail) {
                    revert(abi.decode(_getRevertMsg(result), (string)));
                }
                successes[i] = success;
                results[i] = !success ? _getRevertMsg(result) : result;
            }
        }
    }

    /// @notice Adds assets to the lending pair.
    /// @param from Address to add asset from.
    /// @param to The address of the user to receive the assets.
    /// @param skim True if the amount should be skimmed from the deposit balance of msg.sender.
    /// False if tokens from msg.sender in `yieldBox` should be transferred.
    /// @param share The amount of shares to add.
    /// @return fraction Total fractions added.
    function addAsset(address from, address to, bool skim, uint256 share)
        external
        optionNotPaused(PauseType.AddAsset)
        allowedLend(from, share)
        returns (uint256 fraction)
    {
        _accrue();
        fraction = _addAsset(from, to, skim, share);
    }

    /// @notice Removes an asset from `from` and transfers it to `to`.
    /// @param from Account to debit assets from.
    /// @param to The user that receives the removed assets.
    /// @param fraction The amount/fraction of assets held to remove.
    /// @return share The amount of shares transferred to `to`.
    function removeAsset(address from, address to, uint256 fraction)
        external
        optionNotPaused(PauseType.RemoveAsset)
        returns (uint256 share)
    {
        _accrue();
        share = _removeAsset(from, to, fraction);
        _allowedLend(from, share);
    }

    // *********************** //
    // *** OWNER FUNCTIONS *** //
    // *********************** //
    /// @notice updates the pause state of the contract
    /// @dev can only be called by the conservator
    /// @param val the new value
    function updatePause(PauseType _type, bool val, bool resetAccrueTimestmap) external {
        if (msg.sender != conservator) revert NotAuthorized();
        if (val == pauseOptions[_type]) revert SameState();
        emit PausedUpdated(_type, pauseOptions[_type], val);
        pauseOptions[_type] = val;

        if (val) {
            _accrue();
        }

        // In case of 'unpause', `lastAccrued` is set to block.timestamp
        // Valid for all action types that has an impact on debt or supply
        if (!val && (_type != PauseType.AddCollateral && _type != PauseType.RemoveCollateral)) {
            accrueInfo.lastAccrued = resetAccrueTimestmap ? block.timestamp.toUint64() : accrueInfo.lastAccrued;
        }
    }

    /// @notice rescues unused ETH from the contract
    /// @param amount the amount to rescue
    /// @param to the recipient
    function rescueEth(uint256 amount, address to) external onlyOwner {
        (bool success,) = to.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    /// @notice Transfers fees to penrose
    /// @dev can only be called by the owner
    /// @return feeShares the amount of fees in shares withdrawn under Penrose
    function refreshPenroseFees() external onlyOwner returns (uint256 feeShares) {
        address _feeTo = address(penrose);
        // withdraw the fees accumulated in `accrueInfo.feesEarnedFraction` to the balance of `feeTo`.
        if (accrueInfo.feesEarnedFraction > 0) {
            _accrue();
            uint256 _feesEarnedFraction = accrueInfo.feesEarnedFraction;
            balanceOf[_feeTo] += _feesEarnedFraction;
            emit Transfer(address(0), _feeTo, _feesEarnedFraction);
            accrueInfo.feesEarnedFraction = 0;
            emit LogWithdrawFees(_feeTo, _feesEarnedFraction);
        }

        feeShares = _removeAsset(_feeTo, msg.sender, balanceOf[_feeTo]);
    }

    /// @notice sets Singularity specific configuration
    /// @dev values are updated only if > 0 or not address(0)
    ///     - borrowOpeningFee is always updated!
    function setSingularityConfig(
        uint256 _borrowOpeningFee,
        uint256 _liquidationMultiplier,
        uint256 _minimumTargetUtilization,
        uint256 _maximumTargetUtilization,
        uint64 _minimumInterestPerSecond,
        uint64 _maximumInterestPerSecond,
        uint256 _interestElasticity
    ) external onlyOwner {
        _accrue();

        if (_borrowOpeningFee > FEE_PRECISION) revert NotValid();
        emit LogBorrowingFee(borrowOpeningFee, _borrowOpeningFee);
        borrowOpeningFee = _borrowOpeningFee;

        if (_minimumTargetUtilization > 0) {
            emit MinimumTargetUtilizationUpdated(minimumTargetUtilization, _minimumTargetUtilization);
            minimumTargetUtilization = _minimumTargetUtilization;
        }

        if (_maximumTargetUtilization > 0) {
            if (_maximumTargetUtilization >= FULL_UTILIZATION) {
                revert NotValid();
            }

            emit MaximumTargetUtilizationUpdated(maximumTargetUtilization, _maximumTargetUtilization);
            maximumTargetUtilization = _maximumTargetUtilization;
            fullUtilizationMinusMax = FULL_UTILIZATION - maximumTargetUtilization;
        }

        if (_minimumInterestPerSecond > 0) {
            if (_minimumInterestPerSecond >= maximumInterestPerSecond) {
                revert NotValid();
            }
            emit MinimumInterestPerSecondUpdated(minimumInterestPerSecond, _minimumInterestPerSecond);
            minimumInterestPerSecond = _minimumInterestPerSecond;
        }

        if (_maximumInterestPerSecond > 0) {
            if (_maximumInterestPerSecond <= minimumInterestPerSecond) {
                revert NotValid();
            }
            emit MaximumInterestPerSecondUpdated(maximumInterestPerSecond, _maximumInterestPerSecond);
            maximumInterestPerSecond = _maximumInterestPerSecond;
        }

        if (_interestElasticity > 0) {
            emit InterestElasticityUpdated(interestElasticity, _interestElasticity);
            interestElasticity = _interestElasticity;
        }

        if (_liquidationMultiplier > 0) {
            if (_liquidationMultiplier > FEE_PRECISION) revert NotValid();
            emit LiquidationMultiplierUpdated(liquidationMultiplier, _liquidationMultiplier);
            liquidationMultiplier = _liquidationMultiplier;
        }
    }

    // ************************* //
    // *** PRIVATE FUNCTIONS *** //
    // ************************* //
    function _extractModule(Module _module) private view returns (address) {
        address module;
        if (_module == Module.Base) {
            return address(this);
        } else if (_module == Module.Borrow) {
            module = address(borrowModule);
        } else if (_module == Module.Collateral) {
            module = address(collateralModule);
        } else if (_module == Module.Liquidation) {
            module = address(liquidationModule);
        } else if (_module == Module.Leverage) {
            module = address(leverageModule);
        }
        if (module == address(0)) revert ModuleNotSet();

        return module;
    }

    receive() external payable {}
}
