// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;
import "../interfaces/IRewarderTDog.sol";
import "@boringcrypto/boring-solidity/contracts/libraries/BoringERC20.sol";
import "@boringcrypto/boring-solidity/contracts/libraries/BoringMath.sol";
import "@boringcrypto/boring-solidity/contracts/BoringOwnable.sol";
import "../TopDogV2.sol";

/// @author @0xKeno
contract ComplexRewarderTopDog is IRewarderTDog,  BoringOwnable{
    using BoringMath for uint256;
    using BoringMath128 for uint128;
    using BoringERC20 for IERC20;

    IERC20 private immutable rewardToken;

    /// @notice Info of each MCV2 user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of BONE entitled to the user.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    /// @notice Info of each MCV2 pool.
    /// `allocPoint` The amount of allocation points assigned to the pool.
    /// Also known as the amount of BONE to distribute per block.
    struct PoolInfo {
        uint128 accBonePerShare;
        uint64 lastRewardBlock;
        uint64 allocPoint;
    }

    /// @notice Info of each pool.
    mapping (uint256 => PoolInfo) public poolInfo;

    uint256[] public poolIds;

    /// @notice Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 totalAllocPoint;

    uint256 public tokenPerBlock;
    uint256 private constant ACC_TOKEN_PRECISION = 1e12;

    address private immutable TOPDOG_V2;

    event LogOnReward(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event LogPoolAddition(uint256 indexed pid, uint256 allocPoint);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint);
    event LogUpdatePool(uint256 indexed pid, uint64 lastRewardBlock, uint256 lpSupply, uint256 accBonePerShare);
    event LogInit();

    constructor (IERC20 _rewardToken, uint256 _tokenPerBlock, address _TOPDOG_V2) public {
        rewardToken = _rewardToken;
        tokenPerBlock = _tokenPerBlock;
        TOPDOG_V2 = _TOPDOG_V2;
    }


    function onBoneReward (uint256 pid, address _user, address to, uint256, uint256 lpToken) onlyMCV2 override external {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][_user];
        uint256 pending;
        if (user.amount > 0) {
            pending =
                (user.amount.mul(pool.accBonePerShare) / ACC_TOKEN_PRECISION).sub(
                    user.rewardDebt
                );
            rewardToken.safeTransfer(to, pending);
        }
        user.amount = lpToken;
        user.rewardDebt = lpToken.mul(pool.accBonePerShare) / ACC_TOKEN_PRECISION;
        emit LogOnReward(_user, pid, pending, to);
    }
    
    function pendingTokens(uint256 pid, address user, uint256) override external view returns (IERC20[] memory rewardTokens, uint256[] memory rewardAmounts) {
        IERC20[] memory _rewardTokens = new IERC20[](1);
        _rewardTokens[0] = (rewardToken);
        uint256[] memory _rewardAmounts = new uint256[](1);
        _rewardAmounts[0] = pendingToken(pid, user);
        return (_rewardTokens, _rewardAmounts);
    }

    modifier onlyMCV2 {
        require(
            msg.sender == TOPDOG_V2,
            "Only MCV2 can call this function."
        );
        _;
    }

    /// @notice Returns the number of MCV2 pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolIds.length;
    }

    /// @notice Add a new LP to the pool.  Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    /// @param allocPoint AP of the new pool.
    /// @param _pid Pid on MCV2
    function add(uint256 allocPoint, uint256 _pid) public onlyOwner {
        require(poolInfo[_pid].lastRewardBlock == 0, "Pool already exists");
        uint256 lastRewardBlock = block.number;
        totalAllocPoint = totalAllocPoint.add(allocPoint);

        poolInfo[_pid] = PoolInfo({
            allocPoint: allocPoint.to64(),
            lastRewardBlock: lastRewardBlock.to64(),
            accBonePerShare: 0
        });
        poolIds.push(_pid);
        emit LogPoolAddition(_pid, allocPoint);
    }

    /// @notice Update the given pool's BONE allocation point and `IRewarderTDog` contract. Can only be called by the owner.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _allocPoint New AP of the pool.
    function set(uint256 _pid, uint256 _allocPoint) public onlyOwner {
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint.to64();
        emit LogSetPool(_pid, _allocPoint);
    }

    /// @notice View function to see pending Token
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user Address of user.
    /// @return pending BONE reward for a given user.
    function pendingToken(uint256 _pid, address _user) public view returns (uint256 pending) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accBonePerShare = pool.accBonePerShare;
        uint256 lpSupply = TopDogV2(TOPDOG_V2).lpToken(_pid).balanceOf(TOPDOG_V2);
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 blocks = block.number.sub(pool.lastRewardBlock);
            uint256 boneReward = blocks.mul(tokenPerBlock).mul(pool.allocPoint) / totalAllocPoint;
            accBonePerShare = accBonePerShare.add(boneReward.mul(ACC_TOKEN_PRECISION) / lpSupply);
        }
        pending = (user.amount.mul(accBonePerShare) / ACC_TOKEN_PRECISION).sub(user.rewardDebt);
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
        require(pool.lastRewardBlock != 0, "Pool does not exist");
        if (block.number > pool.lastRewardBlock) {
            uint256 lpSupply = TopDogV2(TOPDOG_V2).lpToken(pid).balanceOf(TOPDOG_V2);

            if (lpSupply > 0) {
                uint256 blocks = block.number.sub(pool.lastRewardBlock);
                uint256 boneReward = blocks.mul(tokenPerBlock).mul(pool.allocPoint) / totalAllocPoint;
                pool.accBonePerShare = pool.accBonePerShare.add((boneReward.mul(ACC_TOKEN_PRECISION) / lpSupply).to128());
            }
            pool.lastRewardBlock = block.number.to64();
            poolInfo[pid] = pool;
            emit LogUpdatePool(pid, pool.lastRewardBlock, lpSupply, pool.accBonePerShare);
        }
    }

}
