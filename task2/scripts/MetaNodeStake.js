const {ethers,upgrades} = require("hardhat");

async function main() { 
    const MetaNodeToken = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
    const startBlock = 6529999;
    const endBlock = 9529999;
    const MetaNpdePerBlock = "20000000000000000";
    const Stake = await ethers.getContractFactory("MetaNodeStake");
    console.log("Deploying MetaNodeStake...");
    const stake = await upgrades.deployProxy(Stake, [MetaNodeToken, startBlock, endBlock, MetaNpdePerBlock], { initializer: 'initialize' });
    console.log("MetaNodeStake deployed to:", await stake.getAddress());
}
main();