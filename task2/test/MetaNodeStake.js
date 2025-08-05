const { ethers, upgrades } = require("hardhat");
const { expect } = require("chai");
const { parseUnits } = require("ethers");

describe('MetaNodeStake', function () {
  let metaNodeStake;
  let metaNodeToken;
  let admin, user1, user2;

  const startBlock = 1;
  const endBlock = 999999999999;
  let metaNodePerBlock;

  beforeEach(async function () {
    metaNodePerBlock = parseUnits("1", 18);
    [admin, user1, user2] = await ethers.getSigners();

    // 部署 MetaNodeToken
    const MetaNodeToken = await ethers.getContractFactory("MetaNodeToken");
    metaNodeToken = await MetaNodeToken.deploy();
    await metaNodeToken.waitForDeployment();
    const metaNodeTokenAddress = await metaNodeToken.getAddress();
    console.log("MetaNodeToken deployed to:", metaNodeTokenAddress);

    // 部署 MetaNodeStake（代理）
    const MetaNodeStake = await ethers.getContractFactory("MetaNodeStake");
    const proxy = await upgrades.deployProxy(
      MetaNodeStake,
      [metaNodeTokenAddress, startBlock, endBlock, metaNodePerBlock],
      { initializer: 'initialize' }
    );
    await proxy.waitForDeployment();

    // 重新附加合约实例，保证有 connect 等方法
    const stakeAddress = await proxy.getAddress();
    metaNodeStake = await ethers.getContractAt("MetaNodeStake", stakeAddress);
    console.log("MetaNodeStake deployed to:", stakeAddress);

    // 转账：给 user1 一部分，剩下的给 stake 合约
    const token = await metaNodeToken.balanceOf(admin.address);
    const userAmount = parseUnits("1000", 18);
    await metaNodeToken.transfer(user1.address, userAmount);

    const stakeAmount = token - userAmount;
    await (await metaNodeToken.transfer(stakeAddress, stakeAmount)).wait();
    console.log("Stake contract funded:", stakeAmount.toString());
  });

  it("admin can set MetaNode token contract", async function () {

    // admin 设置会成功，并触发事件
    await expect(
      metaNodeStake.connect(admin).setMetaNode(metaNodeToken.getAddress())
    )
      .to.emit(metaNodeStake, "SetMetaNode")
      .withArgs(metaNodeToken.getAddress());
  });

  it("non-admin cannot setMetaNode", async function() {
    // 非 admin 设置会失败
    const adminRole = await metaNodeStake.ADMIN_ROLE();
    await expect(
      metaNodeStake.connect(user1).setMetaNode(metaNodeToken.getAddress())
    ).to.be.revertedWithCustomError(metaNodeStake, "AccessControlUnauthorizedAccount")
      .withArgs(user1.address, adminRole);
  });

  it("admin can add pool", async function () {
    await expect(metaNodeStake.connect(user1).addPool(ethers.ZeroAddress, 500, 100, 20, true))
    .to.be.revertedWithCustomError(metaNodeStake, "AccessControlUnauthorizedAccount")
  
    await expect(metaNodeStake.connect(admin).addPool(ethers.ZeroAddress, 500, 100, 20, true))
      .to.emit(metaNodeStake, "AddPool");
  
    let length = await metaNodeStake.poolLength();
    expect(length).to.equal(1);
    await expect(metaNodeStake.connect(admin).addPool(metaNodeToken.getAddress(), 500, 100, 20, true))
      .to.emit(metaNodeStake, "AddPool");
  
    length = await metaNodeStake.poolLength();
    expect(length).to.equal(2);
  });
  
  it("user can deposit tokens into pool", async function () {
    // 先添加池子
    await metaNodeStake.connect(admin).addPool(ethers.ZeroAddress, 100, 100, 20, true);
    await metaNodeStake.connect(admin).addPool(metaNodeToken.getAddress(), 100, 100, 20, true);
    // user1 授权合约转代币
    await metaNodeToken.connect(user1).approve(metaNodeStake.getAddress(), parseUnits("100", 18));
  
    // user1 存入 100 个代币
    await expect(metaNodeStake.connect(user1).deposit(1, parseUnits("100", 18)))
      .to.emit(metaNodeStake, "Deposit")
      .withArgs(user1.address, 1, parseUnits("100", 18));
  
    // 查询用户质押余额
    const balance = await metaNodeStake.stakingBalance(1, user1.address);
    expect(balance).to.equal(parseUnits("100", 18));
  });

  it("user can request unstake", async function () {
    // 先添加池子
    await metaNodeStake.connect(admin).addPool(ethers.ZeroAddress, 100, 100, 20, true);
    await metaNodeStake.connect(admin).addPool(metaNodeToken.getAddress(), 100, 100, 20, true);
    // user1 授权合约转代币
    await metaNodeToken.connect(user1).approve(metaNodeStake.getAddress(), parseUnits("100", 18));
  
    // user1 存入 100 个代币
    await metaNodeStake.connect(user1).deposit(1, parseUnits("100", 18));
  
    // 用户发起 unstake 请求
    await expect(metaNodeStake.connect(user1).unstake(1, parseUnits("50", 18)))
      .to.emit(metaNodeStake, "RequestUnstake")
      .withArgs(user1.address, 1, parseUnits("50", 18));
  
    // 查询用户 stakingBalance 减少
    const balance = await metaNodeStake.stakingBalance(1, user1.address);
    expect(balance).to.equal(parseUnits("50", 18));
  });

  it("user can withdraw after unstake locked blocks", async function () {
    // 先添加池子
    await metaNodeStake.connect(admin).addPool(ethers.ZeroAddress, 100, 100, 5, true);
    await metaNodeStake.connect(admin).addPool(metaNodeToken.getAddress(), 100, 100, 5, true);
    // user1 授权合约转代币
    await metaNodeToken.connect(user1).approve(metaNodeStake.getAddress(), parseUnits("100", 18));
  
    // user1 存入 100 个代币
    await metaNodeStake.connect(user1).deposit(1, parseUnits("100", 18));
  
    // 发起 unstake 50
    await metaNodeStake.connect(user1).unstake(1, parseUnits("50", 18));
  
    // 快进区块，跳过锁定期
    for (let i = 0; i < 6; i++) {
      await ethers.provider.send("evm_mine");
    }
  
    // 记录余额
    const beforeBalance = await metaNodeToken.balanceOf(user1.address);
  
    // 提现
    const tx = await metaNodeStake.connect(user1).withdraw(1);
    const receipt = await tx.wait();
    const eventBlockNumber = receipt.blockNumber;

    await expect(tx)
      .to.emit(metaNodeStake, "Withdraw")
      .withArgs(user1.address, 1, parseUnits("50", 18), eventBlockNumber);
  
    // 用户代币余额增加
    const afterBalance = await metaNodeToken.balanceOf(user1.address);
    expect(afterBalance -beforeBalance).to.equal(parseUnits("50", 18));
  });
  
  it("user can claim MetaNode rewards", async function () {
    // 先添加池子
    await metaNodeStake.connect(admin).addPool(ethers.ZeroAddress, 100, 100, 5, true);
    await metaNodeStake.connect(admin).addPool(metaNodeToken.getAddress(), 100, 100, 5, true);
    // user1 授权合约转代币
    await metaNodeToken.connect(user1).approve(metaNodeStake.getAddress(), parseUnits("100", 18));
  
    // user1 存入 100 个代币
    await metaNodeStake.connect(user1).deposit(1, parseUnits("100", 18));
  
    // 快进区块，跳过锁定期
    for (let i = 0; i < 6; i++) {
      await ethers.provider.send("evm_mine");
    }
  
    const beforeBalance = await metaNodeToken.balanceOf(user1.address);
  
    // 领取奖励
    await expect(metaNodeStake.connect(user1).claim(1))
      .to.emit(metaNodeStake, "Claim");
  
    const afterBalance = await metaNodeToken.balanceOf(user1.address);
    console.log("afterBalance: ", afterBalance);
    expect(afterBalance).to.be.gt(beforeBalance); // 奖励到账了
  });  
});
