// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

// External
import {RebaseLibrary, Rebase} from "@boringcrypto/boring-solidity/contracts/libraries/BoringRebase.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Tapioca
import {IMagnetarHelper} from "tapioca-periph/interfaces/periph/IMagnetarHelper.sol";
import {ICommonData} from "tapioca-periph/interfaces/common/ICommonData.sol";
import {IMagnetar} from "tapioca-periph/interfaces/periph/IMagnetar.sol";
import {ICluster} from "tapioca-periph/interfaces/periph/ICluster.sol";
import {IUSDOBase} from "tapioca-periph/interfaces/bar/IUSDO.sol";
import {IYieldBox} from "tapioca-periph/interfaces/yieldbox/IYieldBox.sol";
import {USDOMarketModule} from "./USDOMarketModule.sol";
import {BaseUSDOStorage} from "../BaseUSDOStorage.sol";
import {LzLib} from "contracts/tmp/LzLib.sol";
import {USDOCommon} from "./USDOCommon.sol";

contract USDOMarketDestinationModule is USDOCommon {
    using RebaseLibrary for Rebase;
    using SafeERC20 for IERC20;

    constructor(address _lzEndpoint, IYieldBox _yieldBox, ICluster _cluster)
        BaseUSDOStorage(_lzEndpoint, _yieldBox, _cluster)
    {}

    /// @notice destination call for USDOMarketModule.sendAndLendOrRepay
    /// @param module USDO MarketDestination module address
    /// @param _srcChainId LayerZero source chain id
    /// @param _srcAddress LayerZero sender
    /// @param _nonce LayerZero current nonce
    /// @param _payload received payload
    function lend(address module, uint16 _srcChainId, bytes memory _srcAddress, uint64 _nonce, bytes memory _payload)
        public
    {
        if (msg.sender != address(this)) revert SenderNotAuthorized();
        if (_moduleAddresses[Module.MarketDestination] != module) {
            revert NotValid();
        }

        USDOMarketModule.LendOrRepayData memory _data = abi.decode(_payload, (USDOMarketModule.LendOrRepayData));

        _data.lendParams.depositAmount = _sd2ld(_data.lendAmountSD);
        uint256 balanceBefore = balanceOf(address(this));
        bool credited = creditedPackets[_srcChainId][_srcAddress][_nonce];
        if (!credited) {
            _creditTo(_srcChainId, address(this), _data.lendParams.depositAmount);
            creditedPackets[_srcChainId][_srcAddress][_nonce] = true;
        }
        uint256 balanceAfter = balanceOf(address(this));

        (bool success, bytes memory reason) = module.delegatecall(
            abi.encodeWithSelector(
                this.lendInternal.selector,
                _data.to,
                _data.lendParams,
                _data.approvals,
                _data.revokes,
                _data.withdrawParams,
                _data.airdropAmount
            )
        );

        if (!success) {
            if (balanceAfter - balanceBefore >= _data.lendParams.depositAmount) {
                IERC20(address(this)).safeTransfer(_data.to, _data.lendParams.depositAmount);
            }
            _storeFailedMessage(_srcChainId, _srcAddress, _nonce, _payload, reason);
            emit CallFailedBytes(_srcChainId, _payload, reason);
        }

        emit ReceiveFromChain(_srcChainId, _data.to, _data.lendParams.depositAmount);
    }

    function lendInternal(
        address to,
        IUSDOBase.ILendOrRepayParams memory lendParams,
        ICommonData.IApproval[] memory approvals,
        ICommonData.IApproval[] memory revokes,
        ICommonData.IWithdrawParams memory withdrawParams,
        uint256 airdropAmount
    ) public payable {
        if (msg.sender != address(this)) revert SenderNotAuthorized();

        if (approvals.length > 0) {
            _callApproval(approvals, PT_YB_SEND_SGL_LEND_OR_REPAY);
        }

        IMagnetar magnetar = IMagnetar(payable(lendParams.marketHelper));
        // Use market helper to deposit and add asset to market
        approve(address(lendParams.marketHelper), lendParams.depositAmount);
        if (lendParams.repay) {
            if (lendParams.repayAmount == 0) {
                lendParams.repayAmount = IMagnetarHelper(magnetar.helper()).getBorrowPartForAmount(
                    lendParams.market, lendParams.depositAmount
                );
            }
            magnetar.depositRepayAndRemoveCollateralFromMarket{value: airdropAmount}(
                IMagnetar.DepositRepayAndRemoveCollateralFromMarketData({
                    market: lendParams.market,
                    user: to,
                    depositAmount: lendParams.depositAmount,
                    repayAmount: lendParams.repayAmount,
                    collateralAmount: lendParams.removeCollateralAmount,
                    extractFromSender: true,
                    withdrawCollateralParams: withdrawParams,
                    valueAmount: airdropAmount
                })
            );
        } else {
            magnetar.mintFromBBAndLendOnSGL{value: airdropAmount}(
                IMagnetar.MintFromBBAndLendOnSGLData({
                    user: to,
                    lendAmount: lendParams.depositAmount,
                    mintData: IUSDOBase.IMintData({
                        mint: false,
                        mintAmount: 0,
                        collateralDepositData: ICommonData.IDepositData({deposit: false, amount: 0, extractFromSender: false})
                    }),
                    depositData: ICommonData.IDepositData({
                        deposit: true,
                        amount: lendParams.depositAmount,
                        extractFromSender: true
                    }),
                    lockData: lendParams.lockData,
                    participateData: lendParams.participateData,
                    externalContracts: ICommonData.ICommonExternalContracts({
                        magnetar: address(0),
                        singularity: lendParams.market,
                        bigBang: address(0)
                    })
                })
            );
        }

        if (revokes.length > 0) {
            _callApproval(revokes, PT_YB_SEND_SGL_LEND_OR_REPAY);
        }
    }

    /// @notice destination call for USDOMarketModule.removeAsset
    /// @param _payload received payload
    function remove(address, uint16, bytes memory, uint64, bytes memory _payload) public {
        if (msg.sender != address(this)) revert SenderNotAuthorized();

        USDOMarketModule.RemoveAssetData memory _data = abi.decode(_payload, (USDOMarketModule.RemoveAssetData));

        //approvals
        if (_data.approvals.length > 0) {
            _callApproval(_data.approvals, PT_MARKET_REMOVE_ASSET);
        }

        IMagnetar(payable(_data.externalData.magnetar)).exitPositionAndRemoveCollateral{value: _data.airdropAmount}(
            IMagnetar.ExitPositionAndRemoveCollateralData({
                user: _data.to,
                externalData: _data.externalData,
                removeAndRepayData: _data.removeAndRepayData,
                valueAmount: _data.airdropAmount
            })
        );

        //revokes
        if (_data.revokes.length > 0) {
            _callApproval(_data.revokes, PT_MARKET_REMOVE_ASSET);
        }
    }
}
