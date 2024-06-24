import { ethers } from "hardhat";
const utils = require("../scripts/utils");

import { config } from "./config";

async function main() {
    const [deployer] = await ethers.getSigners();

    console.log("deployer address:", deployer.address);
    const factory = await ethers.getContractAt("PancakeFactory", config.factory);
    const token = await ethers.getContractAt("BBToken", config.wild);

    const masterChef = await utils.deployAndVerify("MasterChef", [
        token.address,
        config.feeAddress, //dev address
        config.feeAddress, //fee address
        config.zap,
        config.startTime,
    ]);
    // await token.transferOwnership(masterChef.address);
    const wildwethPair = await factory.getPair(config.weth, token.address);
    const wethUSDCPair = await factory.getPair(config.usdc, config.weth);
    
    console.log({
        wethUSDCPair: wethUSDCPair,
    });
    // adding new pool
    console.log("adding new pool...");
    await masterChef.add(800, wildwethPair, 100, false, false);
    await masterChef.add(0, wethUSDCPair, 1000, false, false);
    await masterChef.add(100, config.wild, 300, false, false);
    await masterChef.add(50, config.weth, 300, false, false);
    await masterChef.add(50, config.nft, 0, false, true);

    console.log("done");

    console.log({
        token: token.address,
        masterChef: masterChef.address,
    });
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
