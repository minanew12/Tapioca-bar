import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { verify, updateDeployments, constants } from './utils';
import _ from 'lodash';
import { TContract } from 'tapioca-sdk/dist/shared';
import { getDeployment } from '../tasks/utils';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();
    const chainId = await hre.getChainId();
    const contracts: TContract[] = [];

    console.log('\n Deploying BeachBar');
    const yieldBoxContract = await getDeployment(hre, 'YieldBox');

    const args = [yieldBoxContract.address, constants[chainId].tapAddress];
    await deploy('BeachBar', {
        from: deployer,
        log: true,
        args,
    });
    await verify(hre, 'BeachBar', args);
    const deployedBeachBar = await deployments.get('BeachBar');
    contracts.push({
        name: 'BeachBar',
        address: deployedBeachBar.address,
        meta: { constructorArguments: args },
    });
    console.log(
        `Done. Deployed on ${
            deployedBeachBar.address
        } with args ${JSON.stringify(args)}`,
    );

    await updateDeployments(contracts, chainId);

    console.log('\n Setting feeTo & feeVeTo');
    const beachBarContract = await hre.ethers.getContractAt(
        'BeachBar',
        deployedBeachBar.address,
    );

    await (await beachBarContract.setFeeTo(constants[chainId].feeTo)).wait();
    await (
        await beachBarContract.setFeeVeTap(constants[chainId].feeVeTo)
    ).wait();
    console.log('Done');
};

export default func;
func.tags = ['BeachBar'];
