// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract MetaNodeStake is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable { 
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;

    // INVARIANT
    bytes32 public constant ADMIN_ROLE = keccak256("admin_role");
    bytes32 public constant UPGRADE_ROLE = keccak256("upgrade_role");
    uint256 public constant ETH_PID = 0;

    // DATA STRUCTURE
    struct Pool {
        // Address of staking token
        address stTokenAddress;
        // Weight of pool
        uint256 poolWeight;
        uint256 lastRewardBlock;
        uint256 accMetaNodePerST;
        uint256 stTokenAmount;
        uint256 minDepositAmount;
        uint256 unstakeLockedBlocks;
    }

    struct UnstakeRequest {
        uint256 amount;
        uint256 unlockBlocks;
    }

    struct User {
        uint256 stAmount;
        uint256 finishedMetaNode;
        uint256 pendingMetaNode;
        UnstakeRequest[] requests;
    }

    // STATE VARIABLES
    uint256 public startBlock;
    uint256 public endBlock;
    uint256 public metaNodePerBlock;
    bool public withdrawPaused;
    bool public claimPaused;
    IERC20 public MetaNode;
    uint256 public totalPoolWeight;
    Pool[] public pool;
    mapping(uint256 => mapping(address => User)) public user;

    // EVENT
    event SetMetaNode(IERC20 indexed MetaNode);
    event PauseWithdraw();
    event UnpauseWithdraw();
    event PauseClaim();
    event UnpauseClaim();
    event SetStartBlock(uint256 indexed startBlock);
    event SetEndBlock(uint256 indexed endBlock);
    event SetMetaNodePerBlock(uint256 indexed metaNodePerBlock);
    event AddPool(address indexed stTokenAddress, uint256 indexed poolweight, uint256 indexed lastRewardBlock, uint256 minDepositAmount, uint256 unstakeLockedBlocks);
    event UpdatePoolInfo(uint256 indexed poolId, uint256 indexed minDepositAmount, uint256 indexed unstakeLockedBlocks);
    event SetPoolWeight(uint256 indexed poolId, uint256 indexed poolweight, uint256 totalPoolWeight);
    event UpdatePool(uint256 indexed poolId, uint256 indexed lastRewardBlock, uint256 totalMetaNode);
    event Deposit(address indexed user, uint256 indexed poolId, uint256 amount);
    event RequestUnstake(address indexed user, uint256 indexed poolId, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed poolId, uint256 amount, uint256 indexed blockNumber);
    event Claim(address indexed user, uint256 indexed poolId, uint256 MetaNodeReward);

    // MODIFIER

    modifier checkPid(uint256 _pid) { 
        require(_pid < pool.length, "invalid pid");
        _;
    }

    modifier whenNotClaimPaused() {
        require(!claimPaused, "Claim is paused");
        _;
    }

    modifier whenNotWithdrawPaused() {
        require(!withdrawPaused, "Withdraw is paused");
        _;
    }

    function initialize(IERC20 _MetaNode, uint256 _startBlock, uint256 _endBlock, uint256 _MetaNodePerBlock) public initializer { 
        require(_startBlock < _endBlock && _MetaNodePerBlock > 0, "invalid block range");
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADE_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        setMetaNode(_MetaNode);

        startBlock = _startBlock;
        endBlock = _endBlock;
        metaNodePerBlock = _MetaNodePerBlock;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADE_ROLE) {}

    // ADMIN FUNCTION
    function setMetaNode(IERC20 _MetaNode) public onlyRole(ADMIN_ROLE) {
        MetaNode = _MetaNode;
        emit SetMetaNode(MetaNode);
    }

    function pauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(!withdrawPaused, "Withdraw is paused");
        withdrawPaused = true;
        emit PauseWithdraw();
    }

    function unpauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(withdrawPaused, "Withdraw is not paused");
        withdrawPaused = false;
        emit UnpauseWithdraw();
    }

    function pauseClaim() public onlyRole(ADMIN_ROLE) {
        require(!claimPaused, "Claim is paused");
        claimPaused = true;
        emit PauseClaim();
    }

    function unpauseClaim() public onlyRole(ADMIN_ROLE) {
        require(claimPaused, "Claim is not paused");
        claimPaused = false;
        emit UnpauseClaim();
    }

    function setStartBlock(uint256 _startBlock) public onlyRole(ADMIN_ROLE) {
        require(_startBlock <= endBlock, "Start block must be less than end block");
        startBlock = _startBlock;
        emit SetStartBlock(startBlock);
    }

    function setEndBlock(uint256 _endBlock) public onlyRole(ADMIN_ROLE) {
        require(_endBlock >= startBlock, "End block must be greater than start block");
        endBlock = _endBlock;
        emit SetEndBlock(endBlock);
    }

    function setMetaNodePerBlock(uint256 _metaNodePerBlock) public onlyRole(ADMIN_ROLE) {
        require(_metaNodePerBlock > 0, "metaNodePerBlock must be greater than 0");
        metaNodePerBlock = _metaNodePerBlock;
        emit SetMetaNodePerBlock(metaNodePerBlock);
    }

    function addPool(address _stTokenAddress, uint256 _poolWeight, uint256 _minDepositAmount, uint256 _unstakeLockedBlocks, bool _withUpdate) public onlyRole(ADMIN_ROLE) {
        if (pool.length > 0) {
            require(_stTokenAddress != address(0x0), "stTokenAddress must be a valid address");
        } else {
            require(_stTokenAddress == address(0x0), "stTokenAddress must be zero address");
        }
        require(_unstakeLockedBlocks > 0, "unstakeLockedBlocks must be greater than 0");
        require(block.number < endBlock, "endBlock must be greater than current block number");

        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalPoolWeight = totalPoolWeight + _poolWeight;
        pool.push(Pool({
            stTokenAddress: _stTokenAddress,
            poolWeight: _poolWeight,
            stTokenAmount: 0,
            lastRewardBlock: lastRewardBlock,
            accMetaNodePerST: 0,
            unstakeLockedBlocks: _unstakeLockedBlocks,
            minDepositAmount: _minDepositAmount
        }));
        emit AddPool(_stTokenAddress, _poolWeight, lastRewardBlock, _minDepositAmount, _unstakeLockedBlocks);
    }

    function updatePool(uint256 _pid, uint256 _minDepositAmount, uint256 _unstakeLockedBlocks) public onlyRole(ADMIN_ROLE) checkPid(_pid) { 
        pool[_pid].minDepositAmount = _minDepositAmount;
        pool[_pid].unstakeLockedBlocks = _unstakeLockedBlocks;
        emit UpdatePoolInfo(_pid, _minDepositAmount, _unstakeLockedBlocks);
    }

    function setPoolWeight(uint256 _pid, uint256 _poolWeight, bool _withUpdate) public onlyRole(ADMIN_ROLE) checkPid(_pid) { 
        require(_poolWeight > 0, "Pool weight must be greater than 0");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalPoolWeight = totalPoolWeight +_poolWeight - pool[_pid].poolWeight;
        pool[_pid].poolWeight = _poolWeight;
        emit SetPoolWeight(_pid, _poolWeight, totalPoolWeight);
    }

    // QUERY FUNCTION
    function poolLength() external view returns (uint256) {
        return pool.length;
    }

    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256 multiplier) {
        require(_from <= _to, "getMultiplier: invalid range");
        if (_from <= startBlock) {
            _from = startBlock;
        }
        if (_to <= startBlock) {
            _to = startBlock;
        }
        require(_from <= _to, "end block must be greater than start block");
        bool success;
        (success, multiplier) = (_to - _from).tryMul(metaNodePerBlock);
        require(success, "getMultiplier: multiplication overflow");
    }

    function pendingMetaNode(uint256 _pid, address _user) external checkPid(_pid) view returns (uint256) {
        return pendingMetaNodeByBlockNumber(_pid, _user, block.number);
    }

    function pendingMetaNodeByBlockNumber(uint256 _pid, address _user, uint256 _blockNumber) public checkPid(_pid) view returns (uint256) {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][_user];
        uint256 accMetaNodePerST = pool_.accMetaNodePerST;
        uint256 stSupply = pool_.stTokenAmount;
        if (_blockNumber > pool_.lastRewardBlock && stSupply != 0) {
            uint256 multiplier =  getMultiplier(pool_.lastRewardBlock, _blockNumber);
            uint256 metaNodeForPool = multiplier * pool_.poolWeight / totalPoolWeight;
            accMetaNodePerST = accMetaNodePerST + metaNodeForPool * (1 ether) / stSupply;
        }
        return user_.stAmount * accMetaNodePerST / (1 ether) - user_.finishedMetaNode + user_.pendingMetaNode;
    }

    function stakingBalance(uint256 _pid, address _user) external checkPid(_pid) view returns (uint256) {
        return user[_pid][_user].stAmount;
    }

    function withdrawAmount(uint256 _pid, address _user) public checkPid(_pid) view returns (uint256 requestAmount, uint256 pendingWithdrawaAmount) {
        User storage user_ = user[_pid][_user];
        for (uint256 i = 0; i < user_.requests.length; i++) {
            if (user_.requests[i].unlockBlocks <= block.number) {
                pendingWithdrawaAmount += user_.requests[i].amount; 
            }
            requestAmount += user_.requests[i].amount;
        }
    }

    // PUBLIC FUNCTION

    function updatePool(uint256 _pid) public checkPid(_pid) {
        Pool storage pool_ = pool[_pid]; 
        if (block.number <= pool_.lastRewardBlock) {
            return;
        }
        (bool success1, uint256 totalMetaNode) = getMultiplier(pool_.lastRewardBlock, block.number).tryMul(pool_.poolWeight);
        require(success1, "Error: getMultiplier() failed");
        (success1, totalMetaNode) = totalMetaNode.tryDiv(totalPoolWeight);
        require(success1, "Error: totalMetaNode.tryDiv(totalPoolWeight) failed");
        uint256 stSupply = pool_.stTokenAmount;
        if (stSupply > 0) {
            (bool success2, uint256 totalMetaNode_) = totalMetaNode.tryMul(1 ether);
            require(success2, "Error: totalMetaNode.tryMul(1 ether) failed");
            (success2, totalMetaNode) = totalMetaNode_.tryDiv(stSupply);
            require(success2, "Error: totalMetaNode_.tryDiv(stSupply) failed");
            (bool success3, uint256 accMetaNodePerST) = pool_.accMetaNodePerST.tryAdd(totalMetaNode_);
            require(success3, "Error: pool_.accMetaNodePerST.tryAdd(totalMetaNode_) failed");
            pool_.accMetaNodePerST = accMetaNodePerST;
        }
        pool_.lastRewardBlock = block.number;
        emit UpdatePool(_pid, pool_.lastRewardBlock, totalMetaNode);
    }

    function massUpdatePools() public { 
        uint256 length = pool.length;
        for (uint256 pid = 0; pid < length; pid++) { 
            updatePool(pid);
        }
    }

    function depositETH() public whenNotPaused() payable { 
        Pool storage pool_ = pool[ETH_PID];
        require(pool_.stTokenAddress == address(0x0), "depositETH: not support");
        uint256 _amount = msg.value;
        require(_amount >= pool_.minDepositAmount, "depositETH: amount less than minDepositAmount");
        _deposit(ETH_PID, _amount);
    }

    function deposit(uint256 _pid, uint256 _amount) public whenNotPaused() checkPid(_pid) {
        require(_pid != ETH_PID, "deposit: not support ETH_PID"); 
        Pool storage pool_ = pool[_pid];
        require(pool_.stTokenAddress != address(0x0), "deposit: not support");
        require(_amount >= pool_.minDepositAmount, "deposit: amount less than minDepositAmount");
        if (_amount > 0) {
            IERC20(pool_.stTokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
        }
        _deposit(_pid, _amount);
    }

    function unstake(uint256 _pid, uint256 _amount) public whenNotPaused() checkPid(_pid) whenNotWithdrawPaused() {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender]; 
        require(user_.stAmount >= _amount, "unstake: amount greater than user amount");
        updatePool(_pid);
        uint256 pendingMetaNode_ = user_.stAmount * pool_.accMetaNodePerST / (1 ether) - user_.finishedMetaNode;
        if(pendingMetaNode_ > 0){
            user_.pendingMetaNode += pendingMetaNode_;
        }
        if (_amount > 0) {
            user_.stAmount -= _amount;
            user_.requests.push(UnstakeRequest({amount: _amount, unlockBlocks: block.number + pool_.unstakeLockedBlocks}));
        }
        pool_.stTokenAmount -= _amount;
        user_.finishedMetaNode = user_.stAmount * pool_.accMetaNodePerST / (1 ether);
        emit RequestUnstake(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid) public whenNotPaused() checkPid(_pid) whenNotWithdrawPaused() { 
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];
        uint256 pengdingWithdraw_;
        uint256 popNum_;
        for (uint256 i = 0; i < user_.requests.length; i++) {
            if (user_.requests[i].unlockBlocks > block.number) {
                break;
            }
            pengdingWithdraw_ += user_.requests[i].amount;
            popNum_++;
        }
        for (uint256 i = 0; i < user_.requests.length - popNum_; i++) {
            user_.requests[i] = user_.requests[i + popNum_];
        }
        for (uint256 i =0; i < popNum_; i++) {
            user_.requests.pop();
        }
        if (pengdingWithdraw_ > 0) {
            if (pool_.stTokenAddress == address(0x0)) {
                _safeETHTransfer(msg.sender, pengdingWithdraw_);
            } else {
                IERC20(pool_.stTokenAddress).safeTransfer(msg.sender,pengdingWithdraw_);
            }
        }
        emit Withdraw(msg.sender, _pid, pengdingWithdraw_, block.number);
    }

    function claim(uint256 _pid) public whenNotPaused() checkPid(_pid) whenNotClaimPaused() { 
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];
        updatePool(_pid);
        uint256 pendingMetaNode_ = user_.stAmount * pool_.accMetaNodePerST / (1 ether) - user_.finishedMetaNode + user_.pendingMetaNode;
        if(pendingMetaNode_ > 0) {
            user_.pendingMetaNode = 0;
            _safeMetaNodeTransfer(msg.sender, pendingMetaNode_);
        }
        user_.finishedMetaNode = user_.stAmount * pool_.accMetaNodePerST / (1 ether);
        emit Claim(msg.sender, _pid, pendingMetaNode_);
    }

    // INTERNAL FUNCTION

    function _deposit(uint256 _pid, uint256 _amount) internal {
        Pool storage pool_ = pool[_pid]; 
        User storage user_ = user[_pid][msg.sender];
        updatePool(_pid);
        if (user_.stAmount > 0) {
            (bool success1, uint256 accST) = user_.stAmount.tryMul(pool_.accMetaNodePerST);
            require(success1, "MetaNode: multiplication overflow");
            (success1, accST) = accST.tryDiv(1 ether);
            require(success1, "MetaNode: division overflow");
            (bool success2, uint256 pendingMetaNode_) = accST.trySub(user_.finishedMetaNode);
            require(success2, "MetaNode: subtraction overflow");
            if (pendingMetaNode_ > 0) { 
                (bool success3, uint256 _pendingMetaNode) = user_.pendingMetaNode.tryAdd(pendingMetaNode_);
                require(success3, "MetaNode: addition overflow");
                user_.pendingMetaNode = _pendingMetaNode;
            }
        }

        if (_amount > 0) {
            (bool success4, uint256 stAmount) = user_.stAmount.tryAdd(_amount);
            require(success4, "MetaNode: addition overflow");
            user_.stAmount = stAmount;
        }
        (bool success5, uint256 stTokenAmount) = pool_.stTokenAmount.tryAdd(_amount);
        require(success5, "MetaNode: addition overflow");
        pool_.stTokenAmount = stTokenAmount;
        (bool success6, uint256 finishedMetaNode) = user_.stAmount.tryMul(pool_.accMetaNodePerST);
        require(success6, "MetaNode: multiplication overflow");
        (success6, finishedMetaNode) = finishedMetaNode.tryDiv(1 ether);
        require(success6, "MetaNode: division overflow");
        user_.finishedMetaNode = finishedMetaNode;
        emit Deposit(msg.sender, _pid, _amount);
    }

    function _safeMetaNodeTransfer(address _to, uint256 _amount) internal { 
        uint256 metaNodeBal = MetaNode.balanceOf(address(this));
        if (_amount > metaNodeBal) {
            MetaNode.transfer(_to, metaNodeBal);
        } else {
            MetaNode.transfer(_to, _amount);
        }
    }

    function _safeETHTransfer(address _to, uint256 _amount) internal { 
        (bool success, bytes memory data) = address(_to).call{value: _amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
        if(data.length > 0) {
            require(abi.decode(data, (bool)), "Address: ETH transfer to non-contract account failed");
        }
    }
}