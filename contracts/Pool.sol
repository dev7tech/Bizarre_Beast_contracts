// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.15;

contract Pool {

    struct PoolInfo {
        address lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. BBs to distribute per block.
        uint256 lastRewardTime; // Last block number that BBs distribution occurs.
        uint256 accBBPerShare; // Accumulated BBs per share, times 1e18. See below.
        uint16 depositFeeBP; // Deposit fee in basis points
        bool isNFTPool; // if lastRewardTime has passed
    }

    PoolInfo[] public poolInfo;


    constructor() {}
    
    modifier validatePoolByPid(uint256 _pid) {
        require(_pid < poolInfo.length, "Pool does not exist");
        _;
    }
    // Info of each pool.
    
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        address _lpToken,
        uint16 _depositFeeBP,
        bool _withUpdate,
        bool _isNFTPool
    ) public onlyOwner {
        require(_depositFeeBP <= 1000, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardTime = block.timestamp > startTime
            ? block.timestamp
            : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardTime: lastRewardTime,
                accBBPerShare: 0,
                depositFeeBP: _depositFeeBP,
                isNFTPool: _isNFTPool
            })
        );
    }

    // Update the given pool's BB allocation point and deposit fee. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        uint256 _startTime,
        bool _withUpdate
    ) public onlyOwner {
        require(_depositFeeBP <= 1000, "set: invalid deposit fee basis points");
        require(_allocPoint <= 1000, "set: invalid alloc point basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].lastRewardTime = _startTime;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        if (pool.isNFTPool) {
            uint256 lpSupply = IERC721(pool.lpToken).balanceOf(address(this));
            if (lpSupply == 0 || pool.allocPoint == 0) {
                pool.lastRewardTime = block.timestamp;
                return;
            }
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 BBReward = multiplier.mul(pool.allocPoint).div(totalAllocPoint);
            BBToken(BB).mint(devaddr, BBReward.div(5));
            BBToken(BB).mint(address(this), BBReward);
            totalDevAlloc += BBReward.div(5);
            pool.accBBPerShare = pool.accBBPerShare.add(BBReward.mul(1e18).div(lpSupply.mul(amountPerNFT)));
            pool.lastRewardTime = block.timestamp;
        } else {
            uint256 lpSupply = IERC20(pool.lpToken).balanceOf(address(this));
            if (lpSupply == 0 || pool.allocPoint == 0) {
                pool.lastRewardTime = block.timestamp;
                return;
            }
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 BBReward = multiplier.mul(pool.allocPoint).div(totalAllocPoint);
            BBToken(BB).mint(devaddr, BBReward.div(5));
            BBToken(BB).mint(address(this), BBReward);
            totalDevAlloc += BBReward.div(5);
            pool.accBBPerShare = pool.accBBPerShare.add(BBReward.mul(1e18).div(lpSupply));
            pool.lastRewardTime = block.timestamp;
        }
    }
}
