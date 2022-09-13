import { time } from '@nomicfoundation/hardhat-network-helpers';
import { BigNumberish } from 'ethers';
import { ethers } from 'hardhat';
import { string } from 'hardhat/internal/core/params/argumentTypes';
import {
    BeachBar,
    ERC20Mock,
    BaseMixologist,
    MixologistLendingBorrowing,
    MixologistLiquidation,
    MixologistSetter,
    OracleMock,
    WETH9Mock,
    YieldBox,
} from '../typechain';
import { MultiSwapper } from '../typechain/MultiSwapper';
import { UniswapV2Factory } from '../typechain/UniswapV2Factory';
import { UniswapV2Router02 } from '../typechain/UniswapV2Router02';

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR);

const mixologistModules = {
    Base: 0,
    LendingBorrowing: 1,
    Liquidation: 2,
    Setter: 3,
};

async function resetVM() {
    await ethers.provider.send('hardhat_reset', []);
}

function BN(n: BigNumberish) {
    return ethers.BigNumber.from(n.toString());
}

const __wethUsdcPrice = BN(1000).mul((1e18).toString());

export async function setBalance(addr: string, ether: number) {
    await ethers.provider.send('hardhat_setBalance', [
        addr,
        ethers.utils.hexStripZeros(ethers.utils.parseEther(String(ether))._hex),
    ]);
}

async function registerUniswapV2() {
    const __uniFactoryFee = ethers.Wallet.createRandom();
    const __uniFactory = await (
        await ethers.getContractFactory('UniswapV2Factory')
    ).deploy(__uniFactoryFee.address);
    await __uniFactory.deployed();
    const __uniRouter = await (
        await ethers.getContractFactory('UniswapV2Router02')
    ).deploy(__uniFactory.address, ethers.constants.AddressZero);
    await __uniRouter.deployed();

    return { __uniFactory, __uniFactoryFee, __uniRouter };
}

async function registerERC20Tokens() {
    // Deploy USDC and WETH
    const usdc = await (
        await ethers.getContractFactory('ERC20Mock')
    ).deploy(ethers.BigNumber.from((1e18).toString()).mul(1e9));
    await usdc.deployed();
    const weth = await (await ethers.getContractFactory('WETH9Mock')).deploy();
    await weth.deployed();

    // Deploy TAP
    const tap = await (
        await ethers.getContractFactory('ERC20Mock')
    ).deploy(ethers.BigNumber.from((1e18).toString()).mul(1e9));
    await tap.deployed();

    return { usdc, weth, tap };
}

async function registerYieldBox(wethAddress: string) {
    // Deploy URIBuilder
    const uriBuilder = await (
        await ethers.getContractFactory('YieldBoxURIBuilder')
    ).deploy();
    await uriBuilder.deployed();

    // Deploy yieldBox
    const yieldBox = await (
        await ethers.getContractFactory('YieldBox')
    ).deploy(ethers.constants.AddressZero, uriBuilder.address);
    await yieldBox.deployed();

    return { uriBuilder, yieldBox };
}

async function registerBeachBar(yieldBox: string, tapAddress: string) {
    const bar = await (
        await ethers.getContractFactory('BeachBar')
    ).deploy(yieldBox, tapAddress);
    await bar.deployed();

    return { bar };
}

async function setBeachBarAssets(
    yieldBox: YieldBox,
    bar: BeachBar,
    wethAddress: string,
    usdcAddress: string,
) {
    await (
        await yieldBox.registerAsset(
            1,
            wethAddress,
            ethers.constants.AddressZero,
            0,
        )
    ).wait();
    const wethAssetId = await yieldBox.ids(
        1,
        wethAddress,
        ethers.constants.AddressZero,
        0,
    );

    await (
        await yieldBox.registerAsset(
            1,
            usdcAddress,
            ethers.constants.AddressZero,
            0,
        )
    ).wait();
    const usdcAssetId = await yieldBox.ids(
        1,
        usdcAddress,
        ethers.constants.AddressZero,
        0,
    );

    return { wethAssetId, usdcAssetId };
}

async function addUniV2UsdoWethLiquidity(
    deployerAddress: string,
    usdo: ERC20Mock,
    weth: WETH9Mock,
    __uniFactory: UniswapV2Factory,
    __uniRouter: UniswapV2Router02,
) {
    const wethPairAmount = ethers.BigNumber.from(1e6).mul((1e18).toString());
    const usdoPairAmount = wethPairAmount.mul(
        __wethUsdcPrice.div((1e18).toString()),
    );
    await weth.freeMint(wethPairAmount);
    await usdo.freeMint(usdoPairAmount);

    await weth.approve(__uniRouter.address, wethPairAmount);
    await usdo.approve(__uniRouter.address, usdoPairAmount);
    await __uniRouter.addLiquidity(
        weth.address,
        usdo.address,
        wethPairAmount,
        usdoPairAmount,
        wethPairAmount,
        usdoPairAmount,
        deployerAddress,
        Math.floor(Date.now() / 1000) + 1000 * 60, // 1min margin
    );
}
async function uniV2EnvironnementSetup(
    deployerAddress: string,
    weth: WETH9Mock,
    usdc: ERC20Mock,
    tap: ERC20Mock,
) {
    // Deploy Uni factory, create pair and add liquidity
    const { __uniFactory, __uniRouter } = await registerUniswapV2();
    await (await __uniFactory.createPair(weth.address, usdc.address)).wait();

    // Free mint test WETH & USDC
    const wethPairAmount = ethers.BigNumber.from(1e6).mul((1e18).toString());
    const usdcPairAmount = wethPairAmount.mul(
        __wethUsdcPrice.div((1e18).toString()),
    );
    await (await weth.freeMint(wethPairAmount)).wait();
    await (await usdc.freeMint(usdcPairAmount)).wait();

    // Create WETH/USDC LP
    await (await weth.approve(__uniRouter.address, wethPairAmount)).wait();
    await (await usdc.approve(__uniRouter.address, usdcPairAmount)).wait();
    await (
        await __uniRouter.addLiquidity(
            weth.address,
            usdc.address,
            wethPairAmount,
            usdcPairAmount,
            wethPairAmount,
            usdcPairAmount,
            deployerAddress,
            Math.floor(Date.now() / 1000) + 1000 * 60, // 1min margin
        )
    ).wait();
    const __wethUsdcMockPair = await __uniFactory.getPair(
        weth.address,
        usdc.address,
    );

    // Free mint test TAP & WETH with a 1:1 ratio
    await (await weth.freeMint(wethPairAmount)).wait();
    await (await tap.freeMint(wethPairAmount)).wait();

    // Create WETH/TAP LP
    await (await weth.approve(__uniRouter.address, wethPairAmount)).wait();
    await (await tap.approve(__uniRouter.address, wethPairAmount)).wait();
    await (
        await __uniRouter.addLiquidity(
            weth.address,
            tap.address,
            wethPairAmount,
            wethPairAmount,
            wethPairAmount,
            wethPairAmount,
            deployerAddress,
            Math.floor(Date.now() / 1000) + 1000 * 60, // 1min margin
        )
    ).wait();
    const __wethTapMockPair = await __uniFactory.getPair(
        weth.address,
        tap.address,
    );

    return { __wethUsdcMockPair, __wethTapMockPair, __uniFactory, __uniRouter };
}

async function registerMultiSwapper(
    bar: BeachBar,
    __uniFactoryAddress: string,
    __uniFactoryPairCodeHash: string,
) {
    const multiSwapper = await (
        await ethers.getContractFactory('MultiSwapper')
    ).deploy(__uniFactoryAddress, bar.address, __uniFactoryPairCodeHash);
    await multiSwapper.deployed();

    await (await bar.setSwapper(multiSwapper.address, true)).wait();

    return { multiSwapper };
}

async function deployMediumRiskMC(bar: BeachBar) {
    const mediumRiskMC = await (
        await ethers.getContractFactory('BaseMixologist')
    ).deploy();
    await mediumRiskMC.deployed();

    await (await bar.registerMasterContract(mediumRiskMC.address, 1)).wait();

    return { mediumRiskMC };
}

async function registerMixologistLendingBorrowingModule() {
    const mixologistLendingBorrowingModule = await (
        await ethers.getContractFactory('MixologistLendingBorrowing')
    ).deploy();
    await mixologistLendingBorrowingModule.deployed();
    return { mixologistLendingBorrowingModule };
}

async function registerMixologistLiquidationModule() {
    const mixologistLiquidationModule = await (
        await ethers.getContractFactory('MixologistLiquidation')
    ).deploy();
    await mixologistLiquidationModule.deployed();
    return { mixologistLiquidationModule };
}

async function registerMixologistSetterModule() {
    const mixologistSetterModule = await (
        await ethers.getContractFactory('MixologistSetter')
    ).deploy();
    await mixologistSetterModule.deployed();
    return { mixologistSetterModule };
}

async function registerMixologist(
    mediumRiskMC: string,
    yieldBox: YieldBox,
    bar: BeachBar,
    weth: WETH9Mock,
    wethAssetId: BigNumberish,
    usdc: ERC20Mock,
    usdcAssetId: BigNumberish,
    wethUsdcOracle: OracleMock,
    collateralSwapPath: string[],
    tapSwapPath: string[],
    mixologistLendingBorrowingModule: MixologistLendingBorrowing,
    mixologistLiquidationModule: MixologistLiquidation,
    mixologistSetterModule: MixologistSetter,
) {
    const data = new ethers.utils.AbiCoder().encode(
        [
            'address',
            'address',
            'uint256',
            'address',
            'uint256',
            'address',
            'address[]',
            'address[]',
            'address',
            'address',
            'address',
        ],
        [
            bar.address,
            weth.address,
            wethAssetId,
            usdc.address,
            usdcAssetId,
            wethUsdcOracle.address,
            collateralSwapPath,
            tapSwapPath,
            mixologistLendingBorrowingModule.address,
            mixologistLiquidationModule.address,
            mixologistSetterModule.address,
        ],
    );
    await (await bar.registerMixologist(mediumRiskMC, data, true)).wait();
    const wethUsdcMixologist = await ethers.getContractAt(
        'BaseMixologist',
        await yieldBox.clonesOf(
            mediumRiskMC,
            (await yieldBox.clonesOfCount(mediumRiskMC)).sub(1),
        ),
    );
    return { wethUsdcMixologist };
}

async function registerUniUsdoToWethBidder(
    uniSwapper: MultiSwapper,
    mixologist: BaseMixologist,
) {
    const usdoToWethBidder = await (
        await ethers.getContractFactory('UniUsdoToWethBidder')
    ).deploy(uniSwapper.address, mixologist.address);
    await usdoToWethBidder.deployed();

    return { usdoToWethBidder };
}
async function deployCurveStableToUsdoBidder(
    mixologist: BaseMixologist,
    bar: BeachBar,
    usdc: ERC20Mock,
    usdo: ERC20Mock,
) {
    const curvePoolMock = await (
        await ethers.getContractFactory('CurvePoolMock')
    ).deploy(usdo.address, usdc.address);
    const curveSwapper = await (
        await ethers.getContractFactory('CurveSwapper')
    ).deploy(curvePoolMock.address, bar.address);

    const stableToUsdoBidder = await (
        await ethers.getContractFactory('CurveStableToUsdoBidder')
    ).deploy(curveSwapper.address, mixologist.address, 2);
    await stableToUsdoBidder.deployed();

    return { stableToUsdoBidder, curveSwapper };
}

async function deployAndSetUsdo(bar: BeachBar) {
    const usdo = await (
        await ethers.getContractFactory('ERC20Mock')
    ).deploy(BN(1e18).mul(1e9).toString());
    await usdo.deployed();

    await await bar.setUsdoToken(usdo.address);

    return { usdo };
}

async function registerLiquidationQueue(
    bar: BeachBar,
    mixologist: BaseMixologist,
    feeCollector: string,
    mixologistSetter: MixologistSetter,
) {
    const liquidationQueue = await (
        await ethers.getContractFactory('LiquidationQueue')
    ).deploy();
    await liquidationQueue.deployed();

    const LQ_META = {
        activationTime: 600, // 10min
        minBidAmount: ethers.BigNumber.from((1e18).toString()).mul(200), // 200 USDC
        closeToMinBidAmount: ethers.BigNumber.from((1e18).toString()).mul(202),
        defaultBidAmount: ethers.BigNumber.from((1e18).toString()).mul(400), // 400 USDC
        feeCollector,
        bidExecutionSwapper: ethers.constants.AddressZero,
        usdoSwapper: ethers.constants.AddressZero,
    };

    const payloadFn = mixologistSetter.interface.encodeFunctionData(
        'setLiquidationQueue',
        [liquidationQueue.address, LQ_META],
    );
    let payloadExecutionData = new ethers.utils.AbiCoder().encode(
        ['uint256', 'bytes'],
        [mixologistModules.Setter, payloadFn],
    );
    let beachBarFn = mixologist.interface.encodeFunctionData('executeModule', [
        payloadExecutionData,
    ]);
    await (
        await bar.executeMixologistFn([mixologist.address], [beachBarFn])
    ).wait();

    return { liquidationQueue, LQ_META };
}

const log = (message: string, staging?: boolean) =>
    staging && console.log(message);
export async function register(staging?: boolean) {
    if (!staging) {
        await resetVM();
    }
    /**
     * INITIAL SETUP
     */
    const deployer = (await ethers.getSigners())[0];

    log('Deploying WETH9Mock', staging);
    // Deploy WethUSDC mock oracle
    const wethUsdcOracle = await (
        await ethers.getContractFactory('OracleMock')
    ).deploy();
    await wethUsdcOracle.deployed();
    await (await wethUsdcOracle.set(__wethUsdcPrice)).wait();

    log('Deploying Tokens', staging);
    // 1 Deploy tokens
    const { tap, usdc, weth } = await registerERC20Tokens();
    log('Deploying YieldBox', staging);
    // 2 Deploy Yieldbox
    const { yieldBox, uriBuilder } = await registerYieldBox(weth.address);
    log('Deploying BeachBar', staging);
    // 2.1 Deploy BeachBar
    const { bar } = await registerBeachBar(yieldBox.address, tap.address);

    log('Deploying UniFactory', staging);
    // 3 Add asset types to BeachBar
    const { usdcAssetId, wethAssetId } = await setBeachBarAssets(
        yieldBox,
        bar,
        weth.address,
        usdc.address,
    );
    // 4 Deploy UNIV2 env
    const { __wethUsdcMockPair, __wethTapMockPair, __uniFactory, __uniRouter } =
        await uniV2EnvironnementSetup(deployer.address, weth, usdc, tap);

    log('Registering MultiSwapper', staging);
    // 5 Deploy MultiSwapper
    const { multiSwapper } = await registerMultiSwapper(
        bar,
        __uniFactory.address,
        await __uniFactory.pairCodeHash(),
    );

    log('Deploying MediumRiskMC', staging);
    // 6  Deploy MediumRisk master contract
    const { mediumRiskMC } = await deployMediumRiskMC(bar);

    log('Registering Mixologist', staging);
    // 7 Deploy WethUSDC medium risk MC clone
    const collateralSwapPath = [usdc.address, weth.address];
    const tapSwapPath = [weth.address, tap.address];

    const { mixologistLendingBorrowingModule } =
        await registerMixologistLendingBorrowingModule();
    const { mixologistLiquidationModule } =
        await registerMixologistLiquidationModule();
    const { mixologistSetterModule } = await registerMixologistSetterModule();

    const { wethUsdcMixologist } = await registerMixologist(
        mediumRiskMC.address,
        yieldBox,
        bar,
        weth,
        wethAssetId,
        usdc,
        usdcAssetId,
        wethUsdcOracle,
        collateralSwapPath,
        tapSwapPath,
        mixologistLendingBorrowingModule,
        mixologistLiquidationModule,
        mixologistSetterModule,
    );

    // 8 Set feeTo & feeVeTap
    const mixologistFeeTo = ethers.Wallet.createRandom();
    const mixologistFeeVeTap = ethers.Wallet.createRandom();
    await bar.setFeeTo(mixologistFeeTo.address);
    await bar.setFeeVeTap(mixologistFeeVeTap.address);

    log('Registering LiquidationQueue', staging);
    // 9 Deploy & set LiquidationQueue
    const feeCollector = new ethers.Wallet(
        ethers.Wallet.createRandom().privateKey,
        ethers.provider,
    );
    const { liquidationQueue, LQ_META } = await registerLiquidationQueue(
        bar,
        wethUsdcMixologist,
        feeCollector.address,
        mixologistSetterModule,
    );

    /**
     * OTHERS
     */

    // Deploy an EOA
    const eoa1 = new ethers.Wallet(
        ethers.Wallet.createRandom().privateKey,
        ethers.provider,
    );

    if (!staging) {
        await setBalance(eoa1.address, 100000);
    }

    // Helper
    const mixologistHelper = await (
        await ethers.getContractFactory('MixologistHelper')
    ).deploy();
    await mixologistHelper.deployed();

    const { usdoToWethBidder } = await registerUniUsdoToWethBidder(
        multiSwapper,
        wethUsdcMixologist,
    );

    const initialSetup = {
        __wethUsdcPrice,
        deployer,
        usdc,
        usdcAssetId,
        weth,
        wethAssetId,
        tap,
        tapSwapPath,
        collateralSwapPath,
        wethUsdcOracle,
        yieldBox,
        bar,
        wethUsdcMixologist,
        mixologistHelper,
        eoa1,
        multiSwapper,
        mixologistFeeTo,
        mixologistFeeVeTap,
        liquidationQueue,
        LQ_META,
        feeCollector,
        usdoToWethBidder,
        mediumRiskMC,
        mixologistLendingBorrowingModule,
        mixologistLiquidationModule,
        mixologistSetterModule,
        __uniFactory,
        __uniRouter,
        __wethUsdcMockPair,
        __wethTapMockPair,
    };

    /**
     * UTIL FUNCS
     */

    const approveTokensAndSetBarApproval = async (account?: typeof eoa1) => {
        const _usdc = account ? usdc.connect(account) : usdc;
        const _weth = account ? weth.connect(account) : weth;
        const _yieldBox = account ? yieldBox.connect(account) : yieldBox;
        await (
            await _usdc.approve(yieldBox.address, ethers.constants.MaxUint256)
        ).wait();
        await (
            await _weth.approve(yieldBox.address, ethers.constants.MaxUint256)
        ).wait();
        await (
            await _yieldBox.setApprovalForAll(wethUsdcMixologist.address, true)
        ).wait();
    };

    const timeTravel = async (seconds: number) => {
        await time.increase(seconds);
    };

    const wethDepositAndAddAsset = async (
        amount: BigNumberish,
        account?: typeof eoa1,
    ) => {
        const _account = account ?? deployer;
        const _yieldBox = account ? yieldBox.connect(account) : yieldBox;
        const _wethUsdcMixologist = account
            ? wethUsdcMixologist.connect(account)
            : wethUsdcMixologist;

        const id = await _wethUsdcMixologist.assetId();
        const _valShare = await _yieldBox.toShare(id, amount, false);
        await (
            await _yieldBox.depositAsset(
                id,
                _account.address,
                _account.address,
                0,
                _valShare,
            )
        ).wait();
        await (
            await _wethUsdcMixologist.addAsset(
                _account.address,
                _account.address,
                false,
                _valShare,
            )
        ).wait();
    };

    const usdcDepositAndAddCollateral = async (
        amount: BigNumberish,
        account?: typeof eoa1,
    ) => {
        const _account = account ?? deployer;
        const _yieldBox = account ? yieldBox.connect(account) : yieldBox;
        const _wethUsdcMixologist = account
            ? wethUsdcMixologist.connect(account)
            : wethUsdcMixologist;

        const id = await _wethUsdcMixologist.collateralId();
        await (
            await _yieldBox.depositAsset(
                id,
                _account.address,
                _account.address,
                amount,
                0,
            )
        ).wait();

        const _valShare = await _yieldBox.balanceOf(_account.address, id);

        const addCollateralFn =
            mixologistLendingBorrowingModule.interface.encodeFunctionData(
                'addCollateral',
                [_account.address, _account.address, false, _valShare],
            );
        const mixologistExecutionData = new ethers.utils.AbiCoder().encode(
            ['uint256', 'bytes'],
            [mixologistModules.LendingBorrowing, addCollateralFn],
        );
        await (
            await _wethUsdcMixologist.executeModule(mixologistExecutionData)
        ).wait();
    };

    const initContracts = async () => {
        await (await weth.freeMint(1000)).wait();
        const mintValShare = await yieldBox.toShare(
            await wethUsdcMixologist.assetId(),
            1000,
            false,
        );
        await (await weth.approve(yieldBox.address, 1000)).wait();
        await (
            await yieldBox.depositAsset(
                await wethUsdcMixologist.assetId(),
                deployer.address,
                deployer.address,
                0,
                mintValShare,
            )
        ).wait();
        await (
            await yieldBox.setApprovalForAll(wethUsdcMixologist.address, true)
        ).wait();
        await (
            await wethUsdcMixologist.addAsset(
                deployer.address,
                deployer.address,
                false,
                mintValShare,
            )
        ).wait();
    };

    const utilFuncs = {
        BN,
        approveTokensAndSetBarApproval,
        wethDepositAndAddAsset,
        usdcDepositAndAddCollateral,
        initContracts,
        timeTravel,
        deployCurveStableToUsdoBidder,
        deployAndSetUsdo,
        addUniV2UsdoWethLiquidity,
        mixologistModules,
    };

    return { ...initialSetup, ...utilFuncs };
}
