// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@boringcrypto/boring-solidity/contracts/libraries/BoringMath.sol";
import "@boringcrypto/boring-solidity/contracts/BoringBatchable.sol";
import "@boringcrypto/boring-solidity/contracts/BoringOwnable.sol";
import "./libraries/SignedSafeMath.sol";
import "./interfaces/IRewarderTDog.sol";
import "./interfaces/ITopDog.sol";

interface IMigratorChef {
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    function migrate(IERC20 token) external returns (IERC20);
}

/// @notice The (older) TopDog contract gives out a constant number of BONE tokens per block.
/// It is the only address with minting rights for BONE.
/// The idea for this TopDog V2 (TDV2) contract is therefore to be the owner of a dummy token
/// that is deposited into the TopDog V1 (TDV1) contract.
/// The allocation point for this pool on TDV1 is the total allocation point for all pools that receive double incentives.
contract DownDogV2 is BoringOwnable, BoringBatchable {
    using BoringMath for uint256;
    using BoringMath128 for uint128;
    using BoringERC20 for IERC20;
    using SignedSafeMath for int256;

    /// @notice Info of each TDV2 user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of BONE entitled to the user.
    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
    }

    /// @notice Info of each TDV2 pool.
    /// `allocPoint` The amount of allocation points assigned to the pool.
    /// Also known as the amount of BONE to distribute per block.
    struct PoolInfo {
        uint128 accBonePerShare;
        uint64 lastRewardTime;
        uint64 allocPoint;
    }

    /// @notice Address of BONE contract.
    IERC20 public immutable BONE;
    // @notice The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;

    /// @notice Info of each TDV2 pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of the LP token for each TDV2 pool.
    IERC20[] public lpToken;
    /// @notice Address of each `IRewarderTDog` contract in TDV2.
    IRewarderTDog[] public rewarder;

    /// @notice Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    uint256 public bonePerSecond;
    uint256 private constant ACC_BONE_PRECISION = 1e12;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event LogPoolAddition(uint256 indexed pid, uint256 allocPoint, IERC20 indexed lpToken, IRewarderTDog indexed rewarder);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint, IRewarderTDog indexed rewarder, bool overwrite);
    event LogUpdatePool(uint256 indexed pid, uint64 lastRewardTime, uint256 lpSupply, uint256 accBonePerShare);
    event LogBonePerSecond(uint256 bonePerSecond);

    /// @param _bone The BONE token contract address.
    constructor(IERC20 _bone) public {
        BONE = _bone;
    }

    /// @notice Returns the number of TDV2 pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice Add a new LP to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    /// @param allocPoint AP of the new pool.
    /// @param _lpToken Address of the LP ERC-20 token.
    /// @param _rewarder Address of the rewarder delegate.
    function add(uint256 allocPoint, IERC20 _lpToken, IRewarderTDog _rewarder) public onlyOwner {
        totalAllocPoint = totalAllocPoint.add(allocPoint);
        lpToken.push(_lpToken);
        rewarder.push(_rewarder);

        poolInfo.push(PoolInfo({
            allocPoint: allocPoint.to64(),
            lastRewardTime: block.timestamp.to64(),
            accBonePerShare: 0
        }));
        emit LogPoolAddition(lpToken.length.sub(1), allocPoint, _lpToken, _rewarder);
    }

    /// @notice Update the given pool's BONE allocation point and `IRewarderTDog` contract. Can only be called by the owner.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _allocPoint New AP of the pool.
    /// @param _rewarder Address of the rewarder delegate.
    /// @param overwrite True if _rewarder should be `set`. Otherwise `_rewarder` is ignored.
    function set(uint256 _pid, uint256 _allocPoint, IRewarderTDog _rewarder, bool overwrite) public onlyOwner {
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint.to64();
        if (overwrite) { rewarder[_pid] = _rewarder; }
        emit LogSetPool(_pid, _allocPoint, overwrite ? _rewarder : rewarder[_pid], overwrite);
    }

    /// @notice Sets the bone per second to be distributed. Can only be called by the owner.
    /// @param _bonePerSecond The amount of Bone to be distributed per second.
    function setBonePerSecond(uint256 _bonePerSecond) public onlyOwner {
        bonePerSecond = _bonePerSecond;
        emit LogBonePerSecond(_bonePerSecond);
    }

    /// @notice Set the `migrator` contract. Can only be called by the owner.
    /// @param _migrator The contract address to set.
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }

    /// @notice Migrate LP token to another LP contract through the `migrator` contract.
    /// @param _pid The index of the pool. See `poolInfo`.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "TopDogV2: no migrator set");
        IERC20 _lpToken = lpToken[_pid];
        uint256 bal = _lpToken.balanceOf(address(this));
        _lpToken.approve(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(_lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "TopDogV2: migrated balance must match");
        lpToken[_pid] = newLpToken;
    }

    /// @notice View function to see pending BONE on frontend.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user Address of user.
    /// @return pending BONE reward for a given user.
    function pendingBone(uint256 _pid, address _user) external view returns (uint256 pending) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accBonePerShare = pool.accBonePerShare;
        uint256 lpSupply = lpToken[_pid].balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 time = block.timestamp.sub(pool.lastRewardTime);
            uint256 boneReward = time.mul(bonePerSecond).mul(pool.allocPoint) / totalAllocPoint;
            accBonePerShare = accBonePerShare.add(boneReward.mul(ACC_BONE_PRECISION) / lpSupply);
        }
        pending = int256(user.amount.mul(accBonePerShare) / ACC_BONE_PRECISION).sub(user.rewardDebt).toUInt256();
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    /// @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    function massUpdatePools(uint256[] calldata pids) external {
        uint256 len = pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pids[i]);
        }
    }

    /// @notice Update reward variables of the given pool.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[pid];
        if (block.timestamp > pool.lastRewardTime) {
            uint256 lpSupply = lpToken[pid].balanceOf(address(this));
            if (lpSupply > 0) {
                uint256 time = block.timestamp.sub(pool.lastRewardTime);
                uint256 boneReward = time.mul(bonePerSecond).mul(pool.allocPoint) / totalAllocPoint;
                pool.accBonePerShare = pool.accBonePerShare.add((boneReward.mul(ACC_BONE_PRECISION) / lpSupply).to128());
            }
            pool.lastRewardTime = block.timestamp.to64();
            poolInfo[pid] = pool;
            emit LogUpdatePool(pid, pool.lastRewardTime, lpSupply, pool.accBonePerShare);
        }
    }

    /// @notice Deposit LP tokens to TDV2 for BONE allocation.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to deposit.
    /// @param to The receiver of `amount` deposit benefit.
    function deposit(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][to];

        // Effects
        user.amount = user.amount.add(amount);
        user.rewardDebt = user.rewardDebt.add(int256(amount.mul(pool.accBonePerShare) / ACC_BONE_PRECISION));

        // Interactions
        IRewarderTDog _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onBoneReward(pid, to, to, 0, user.amount);
        }

        lpToken[pid].safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, pid, amount, to);
    }

    /// @notice Withdraw LP tokens from TDV2.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens.
    function withdraw(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];

        // Effects
        user.rewardDebt = user.rewardDebt.sub(int256(amount.mul(pool.accBonePerShare) / ACC_BONE_PRECISION));
        user.amount = user.amount.sub(amount);

        // Interactions
        IRewarderTDog _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onBoneReward(pid, msg.sender, to, 0, user.amount);
        }
        
        lpToken[pid].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to);
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of BONE rewards.
    function harvest(uint256 pid, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedBone = int256(user.amount.mul(pool.accBonePerShare) / ACC_BONE_PRECISION);
        uint256 _pendingBone = accumulatedBone.sub(user.rewardDebt).toUInt256();

        // Effects
        user.rewardDebt = accumulatedBone;

        // Interactions
        if (_pendingBone != 0) {
            BONE.safeTransfer(to, _pendingBone);
        }

        IRewarderTDog _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onBoneReward( pid, msg.sender, to, _pendingBone, user.amount);
        }

        emit Harvest(msg.sender, pid, _pendingBone);
    }
    
    /// @notice Withdraw LP tokens from TDV2 and harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens and BONE rewards.
    function withdrawAndHarvest(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedBone = int256(user.amount.mul(pool.accBonePerShare) / ACC_BONE_PRECISION);
        uint256 _pendingBone = accumulatedBone.sub(user.rewardDebt).toUInt256();

        // Effects
        user.rewardDebt = accumulatedBone.sub(int256(amount.mul(pool.accBonePerShare) / ACC_BONE_PRECISION));
        user.amount = user.amount.sub(amount);
        
        // Interactions
        BONE.safeTransfer(to, _pendingBone);

        IRewarderTDog _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onBoneReward(pid, msg.sender, to, _pendingBone, user.amount);
        }

        lpToken[pid].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to);
        emit Harvest(msg.sender, pid, _pendingBone);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of the LP tokens.
    function emergencyWithdraw(uint256 pid, address to) public {
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        IRewarderTDog _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onBoneReward(pid, msg.sender, to, 0, 0);
        }

        // Note: transfer can fail or succeed if `amount` is zero.
        lpToken[pid].safeTransfer(to, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount, to);
    }
}
