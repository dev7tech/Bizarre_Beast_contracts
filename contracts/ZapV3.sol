// SPDX-License-Identifier: UNLICENSED






pragma solidity 0.8.15;

import "./ZapBase.sol";

// File: ZapV3.sol

contract ZapV3 is ZapBase {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event ZapIntoFarm(address indexed _recipient, uint256 indexed _pid, uint256 _amount);
    event ZapIntoAC(address indexed _recipient, uint256 indexed _pid, uint256 _amount);
    event ZapIntoBoardroom(address indexed _recipient, address _inputToken, uint256 _amount);
    event ZapIntoBoardrooms(address indexed _recipient, uint256 _lpAmount, uint256 _ssAmount);

    /* ========== BANK ========== */
    function zapIntoFarmWithToken(
        address _inputToken,
        uint256 _amount,
        address _targetToken,
        address _farm,
        uint256 _pid,
        bool _targetIsNative
    ) external nonReentrant returns (uint256 amountOut) {
        //Zap into token.
        amountOut = _universalZap(
            _inputToken, //_inputToken
            _amount, //_amount
            _targetToken, //_targetToken
            address(this), //_recipient
            _targetIsNative
        );

        //Stake in farm.
        IERC20(_targetToken).safeIncreaseAllowance(_farm, amountOut);
        IRewardPool(_farm).depositFor(_pid, amountOut, msg.sender);

        //Emit event.
        emit ZapIntoFarm(msg.sender, _pid, amountOut);
    }

    /* ========== BANK ========== */

    function zapIntoFarmWithETH(
        address _targetToken,
        address _farm,
        uint256 _pid
    ) external payable nonReentrant returns (uint256 amountOut) {
        //Zap into token.
        require(msg.value > 0, "Insufficient ETH");

        amountOut = _universalZapETH(
            msg.value, //_amount
            _targetToken, //_targetToken
            address(this) //_recipient
        );

        //Stake in farm.
        IERC20(_targetToken).safeIncreaseAllowance(_farm, amountOut);
        IRewardPool(_farm).depositFor(_pid, amountOut, msg.sender);

        //Emit event.
        emit ZapIntoFarm(msg.sender, _pid, amountOut);
    }
}
