// SPDX-License-Identifier: UNLICENSED






pragma solidity ^0.8.15;
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import "./BBToken.sol";
import "./Pool.sol";

interface IBBNFT {
    function walletOfOwner(address _owner) external view returns (uint256[] memory);
}

interface IZap {
    function universalZapForCompound(
        address _inputToken,
        uint256 _amount,
        address _targetToken,
        address _recipient
    ) external returns (uint256 amountOut);
}

// MasterChef is the master of BB. He can make BB and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once BB is sufficiently
// distributed and the community can show to govern itself.
//

contract MasterChef is IERC721Receiver, Ownable, ReentrancyGuard, Pool {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 lastWithdrawTime; // We count in timestamps so uin256 is sufficient.
        uint256 lastHarvestTime;
        uint256 harvestTimes;
        uint256[] tokenIds; // NFT token IDs which the user has provided.

        //
        // We do some fancy math here. Basically, any point in time, the amount of BBs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accBBPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accBBPerShare` (and `lastRewardTime`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // The BB TOKEN!
    BBToken public BB;
    // The BB Address
    address public BBAddr;
    // Zap address
    address public zapAddr;
    // Dev address.
    address public devaddr;
    // BB tokens created per block.
    uint256 public BBPerSecond = 0;
    // total dev alloc
    uint256 public totalDevAlloc;
    // Bonus muliplier for early BB makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // maximim compound per day, per user.
    // Deposit Fee address
    address public feeAddress;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The timestamp when BB mining starts.
    uint256 public startTime;
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    uint256 public amountPerNFT = 1000 ether;

    constructor(
        address _BB,
        address _devaddr,
        address _feeAddress1,
        address _zapAddr,
        uint256 _startTime
    ) {
        BB = BBToken(_BB);
        devaddr = _devaddr;
        feeAddress = _feeAddress1;
        startTime = _startTime;
        BBAddr = _BB;
        zapAddr = _zapAddr;
    }

    function onERC721Received(
        address operator,
        address from,
        uint tokenId,
        bytes calldata
    ) external returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime <= startTime) return 0;
        if (_fromTime <= startTime) return _toTime.sub(startTime).mul(BBPerSecond);
        return _toTime.sub(_fromTime).mul(BBPerSecond);
    }

    // View function to see pending BBs on frontend.
    function pendingBB(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accBBPerShare = pool.accBBPerShare;
        if (pool.isNFTPool) {
            uint256 lpSupply = IERC721(pool.lpToken).balanceOf(address(this));
            if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
                uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
                uint256 BBReward = multiplier.mul(pool.allocPoint).div(totalAllocPoint);
                accBBPerShare = accBBPerShare.add(
                    BBReward.mul(1e18).div(lpSupply.mul(amountPerNFT))
                );
            }
            return
                user.amount.mul(amountPerNFT).mul(accBBPerShare).div(1e18).sub(user.rewardDebt);
        } else {
            uint256 lpSupply = IERC20(pool.lpToken).balanceOf(address(this));
            if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
                uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
                uint256 BBReward = multiplier.mul(pool.allocPoint).div(totalAllocPoint);
                accBBPerShare = accBBPerShare.add(BBReward.mul(1e18).div(lpSupply));
            }
            return user.amount.mul(accBBPerShare).div(1e18).sub(user.rewardDebt);
        }
    }

    

    // Deposit LP tokens to MasterChef for BB allocation.
    function deposit(uint256 _pid, uint256 _amount, bool isNFTAll) public nonReentrant {
        _deposit(_pid, _amount, isNFTAll);
    }

    /// @notice Deposit tokens to MasterChef for WILD allocation.
    /// @param _pid pool id to deposit to
    /// @param _amount amount of tokens to deposit. This amount should be approved beforehand
    /// @param _recipient lock period in seconds to lock
    function depositFor(uint256 _pid, uint256 _amount, address _recipient) external nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_recipient];
        updatePool(_pid);
        if (user.amount > 0) {
            if (pool.isNFTPool) {
                uint256 pending = user
                    .amount
                    .mul(amountPerNFT)
                    .mul(pool.accBBPerShare)
                    .div(1e18)
                    .sub(user.rewardDebt);
                if (pending > 0) {
                    safeBBTransfer(_recipient, pending);
                }
            } else {
                uint256 pending = user.amount.mul(pool.accBBPerShare).div(1e18).sub(
                    user.rewardDebt
                );
                if (pending > 0) {
                    safeBBTransfer(_recipient, pending);
                }
            }
        }
        if (_amount > 0) {
            if (pool.isNFTPool) {
                require(IERC721(pool.lpToken).ownerOf(_amount) == _sender, "Invalid owner");
                IERC721(pool.lpToken).safeTransferFrom(_sender, address(this), _amount);
                user.amount = user.amount.add(1);
                user.tokenIds.push(_amount);
            } else {
                IERC20(pool.lpToken).safeTransferFrom(address(_sender), address(this), _amount);
                if (pool.depositFeeBP > 0) {
                    uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);

                    IERC20(pool.lpToken).safeTransfer(feeAddress, depositFee);

                    user.amount = user.amount.add(_amount).sub(depositFee);
                } else {
                    user.amount = user.amount.add(_amount);
                }
            }
        }
        user.rewardDebt = user.amount.mul(pool.accBBPerShare).div(1e18);
        emit Deposit(msg.sender, _pid, _amount);
    }

    function _deposit(
        uint256 _pid,
        uint256 _amount,
        bool isNFTAll
    ) internal validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        address _sender = msg.sender;
        if (user.amount > 0) {
            if (pool.isNFTPool) {
                uint256 pending = user
                    .amount
                    .mul(amountPerNFT)
                    .mul(pool.accBBPerShare)
                    .div(1e18)
                    .sub(user.rewardDebt);
                if (pending > 0) {
                    safeBBTransfer(msg.sender, pending);
                }
            } else {
                uint256 pending = user.amount.mul(pool.accBBPerShare).div(1e18).sub(
                    user.rewardDebt
                );
                if (pending > 0) {
                    safeBBTransfer(msg.sender, pending);
                }
            }
        }
        if (_amount > 0) {
            if (pool.isNFTPool) {
                uint256[] memory tokenIds = IBBNFT(pool.lpToken).walletOfOwner(_sender);
                if (isNFTAll) {
                    if (tokenIds.length > 0) {
                        for (uint256 i = 0; i < tokenIds.length; i++) {
                            IERC721(pool.lpToken).safeTransferFrom(
                                _sender,
                                address(this),
                                tokenIds[i]
                            );
                            user.amount = user.amount.add(1);
                            user.tokenIds.push(tokenIds[i]);
                        }
                    }
                } else {
                    require(tokenIds.length >= _amount, "Invalid token amount");
                    if (tokenIds.length > 0) {
                        for (uint256 i = 0; i < _amount; i++) {
                            IERC721(pool.lpToken).safeTransferFrom(
                                _sender,
                                address(this),
                                tokenIds[i]
                            );
                            user.amount = user.amount.add(1);
                            user.tokenIds.push(tokenIds[i]);
                        }
                    }
                }
            } else {
                IERC20(pool.lpToken).safeTransferFrom(address(_sender), address(this), _amount);
                if (pool.depositFeeBP > 0) {
                    uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);

                    IERC20(pool.lpToken).safeTransfer(feeAddress, depositFee);

                    user.amount = user.amount.add(_amount).sub(depositFee);
                } else {
                    user.amount = user.amount.add(_amount);
                }
            }
        }
        if (pool.isNFTPool) {
            user.rewardDebt = user.amount.mul(amountPerNFT).mul(pool.accBBPerShare).div(1e18);
        } else {
            user.rewardDebt = user.amount.mul(pool.accBBPerShare).div(1e18);
        }
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Function to harvest or compound many pools in a single transaction
    function harvestMany(uint256[] calldata _pids) public nonReentrant {
        for (uint256 index = 0; index < _pids.length; index++) {
            _deposit(_pids[index], 0, false);
        }
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount, bool isNFTAll) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        address _sender = msg.sender;
        if (pool.isNFTPool) {
            uint256 pending = user
                .amount
                .mul(amountPerNFT)
                .mul(pool.accBBPerShare)
                .div(1e18)
                .sub(user.rewardDebt);
            if (pending > 0) {
                safeBBTransfer(msg.sender, pending);
            }
        } else {
            uint256 pending = user.amount.mul(pool.accBBPerShare).div(1e18).sub(user.rewardDebt);
            if (pending > 0) {
                safeBBTransfer(msg.sender, pending);
            }
        }

        if (_amount > 0) {
            if (pool.isNFTPool) {
                uint256[] memory _tokenIds = user.tokenIds;
                if (isNFTAll) {
                    if (_tokenIds.length > 0) {
                        uint256[] memory empyArr;
                        user.tokenIds = empyArr;
                        for (uint256 i = 0; i < _tokenIds.length; i++) {
                            user.amount = user.amount.sub(1);
                            IERC721(pool.lpToken).safeTransferFrom(
                                address(this),
                                _sender,
                                _tokenIds[i]
                            );
                        }
                    }
                } else {
                    require(_tokenIds.length >= _amount, "Invalid token amount");
                    if (_tokenIds.length > 0) {
                        uint256[] memory newArr = new uint256[](_tokenIds.length - _amount);
                        for (uint256 i = _amount; i < _tokenIds.length; i++) {
                            newArr[i - _amount] = _tokenIds[i];
                        }
                        user.tokenIds = newArr;
                        for (uint256 i = 0; i < _amount; i++) {
                            user.amount = user.amount.sub(1);
                            IERC721(pool.lpToken).safeTransferFrom(
                                address(this),
                                _sender,
                                _tokenIds[i]
                            );
                        }
                    }
                }
            } else {
                require(user.amount >= _amount, "withdraw: not good");
                if (_amount > 0) {
                    user.amount = user.amount.sub(_amount);
                    IERC20(pool.lpToken).safeTransfer(_sender, _amount);
                }
            }
        }
        user.rewardDebt = user.amount.mul(pool.accBBPerShare).div(1e18);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        address _sender = msg.sender;
        user.amount = 0;
        user.rewardDebt = 0;
        if (pool.isNFTPool) {
            uint256[] memory _tokenIds = user.tokenIds;
            uint256[] memory empyArr;
            user.tokenIds = empyArr;
            for (uint256 i = 0; i < _tokenIds.length; i++) {
                IERC721(pool.lpToken).safeTransferFrom(address(this), _sender, _tokenIds[i]);
            }
        } else {
            IERC20(pool.lpToken).safeTransfer(_sender, amount);
        }
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe BB transfer function, just in case if rounding error causes pool to not have enough BBs.
    function safeBBTransfer(address _to, uint256 _amount) internal {
        uint256 BBBal = BB.balanceOf(address(this));
        if (_amount > BBBal) {
            BB.transfer(_to, BBBal);
        } else {
            BB.transfer(_to, _amount);
        }
    }

    function compound(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amountOut = 0;
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accBBPerShare).div(1e18).sub(user.rewardDebt);
            uint256 BBBal = BB.balanceOf(address(this));

            if (user.amount > 0) {
                if (pending > 0) {
                    if (pending > BBBal) {
                        IERC20(BBAddr).safeIncreaseAllowance(address(zapAddr), BBBal);
                        amountOut = IZap(zapAddr).universalZapForCompound(
                            BBAddr, //_inputToken
                            BBBal, //_amount
                            pool.lpToken, //_targetToken
                            address(this) //_recipient
                        );
                    } else {
                        IERC20(BBAddr).safeIncreaseAllowance(address(zapAddr), pending);
                        amountOut = IZap(zapAddr).universalZapForCompound(
                            BBAddr, //_inputToken
                            pending, //_amount
                            pool.lpToken, //_targetToken
                            address(this) //_recipient
                        );
                    }
                }
            }

            if (amountOut > 0) {
                if (pool.depositFeeBP > 0) {
                    uint256 depositFee = amountOut.mul(pool.depositFeeBP).div(10000);
                    IERC20(pool.lpToken).safeTransfer(feeAddress, depositFee);
                    user.amount = user.amount.add(amountOut).sub(depositFee);
                } else {
                    user.amount = user.amount.add(amountOut);
                }
            }
            user.rewardDebt = user.amount.mul(pool.accBBPerShare).div(1e18);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    function setFeeAddress1(address _feeAddress1) public {
        require(msg.sender == feeAddress, "setFeeAddress1: FORBIDDEN");
        feeAddress = _feeAddress1;
    }

    function updateEmissionRate(uint256 _BBPerSecond) public onlyOwner {
        massUpdatePools();
        BBPerSecond = _BBPerSecond;
    }

    function setWildX(address _BB) public onlyOwner {
        require(_BB != address(0), "Invalid Address");
        BB = BBToken(_BB);
    }

    function setAmountPerNFT(uint256 _newAmount) external onlyOwner {
        require(_newAmount > 0, "invalid amount");
        amountPerNFT = _newAmount;
    }

    function getAmountPerNFT() public view returns (uint256) {
        return amountPerNFT;
    }

    function getUserStakedNFTs(uint256 _pid, address _user) public view returns (uint256[] memory) {
        return userInfo[_pid][_user].tokenIds;
    }
}
