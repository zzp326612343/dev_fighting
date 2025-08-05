const {ethers, upgrades} = require("hardhat");

async function main() { 
    const [signer] = await ethers.getSigners();
    const MetaNodeToken = await ethers.getContractFactory("MetaNodeToken");
    const metaNodeToken = await MetaNodeToken.deploy();
    await metaNodeToken.waitForDeployment();
    metaNodeTokenAddress = await metaNodeToken.getAddress();
    console.log("MetaNodeToken deployed to:",metaNodeTokenAddress);

    const MetaNodeStake = await ethers.getContractFactory("MetaNodeStake");
    const startBlock = 1; // 替换为实际起始区块
    const endBlock = 999999999999; // 替换为实际结束区块
    const metaNodePerBlock = ethers.parseUnits("1", 18); // 每区块奖励1个MetaNode（18位精度）
    const stake = await upgrades.deployProxy(MetaNodeStake, [metaNodeTokenAddress, startBlock, endBlock, metaNodePerBlock], { initializer: 'initialize' });
    await stake.waitForDeployment();
    const stakeAddress = await stake.getAddress();
    const token = await metaNodeToken.balanceOf(signer.address);
    let tx = await metaNodeToken.connect(signer).transfer(stakeAddress, token);
    console.log("stake transfer success:",stakeAddress);
}
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });