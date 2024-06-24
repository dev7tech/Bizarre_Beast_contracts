// SPDX-License-Identifier: UNLICENSED









pragma solidity 0.8.15;

import "./pancakeSwap/interfaces/IPancakeFactory.sol";
import "./pancakeSwap/interfaces/IPancakeRouter02.sol";
import "./pancakeSwap/interfaces/IPancakePair.sol";
import "./pancakeSwap/libraries/TransferHelper.sol";
import "./interfaces/MultipleOperator.sol";
import "./interfaces/IRewardPool.sol";
import "./pancakeSwap/interfaces/IWETH.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./BBToken.sol";

// Part: ZapBase

contract ZapBase is MultipleOperator, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    address public WETH;
    address public mainToken;
    address public mainTokenLP;
    address public deadAddress = address(0x000000000000000000000000000000000000dEaD);

    IPancakeRouter02 private ROUTER;
    address PancakeSwapFactory;
    enum TokenType {
        INVALID,
        ERC20,
        LP
    }
    mapping(address => TokenType) public tokenType; //Type of token @ corresponding address.
    mapping(address => mapping(address => address[])) public swapPath; // Paths for swapping 2 given tokens.

    event TaxPaid(address indexed user, uint256 amount);
    event AddLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountInA,
        uint256 amountInB,
        uint256 amountOut
    );
    event SwapTokens(address tokenA, address tokenB, uint256 amountInA, uint256 amountOut);

    /* ========== CONSTRUCTOR ========== */

    function setCoreValues(
        address _router,
        address factory,
        address _mainToken,
        address _mainTokenLP,
        address _weth
    ) external onlyOwner {
        mainToken = _mainToken;
        mainTokenLP = _mainTokenLP;
        WETH = _weth;
        PancakeSwapFactory = factory;
        ROUTER = IPancakeRouter02(_router);

        tokenType[WETH] = TokenType.ERC20;
        tokenType[mainToken] = TokenType.ERC20;
        tokenType[mainTokenLP] = TokenType.LP;
    }

    /*
     * @notice Fallback for WBNB
     */
    receive() external payable {}

    function sortTokens(
        address tokenA,
        address tokenB
    ) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "Zap: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "Zap: ZERO_ADDRESS");
    }

    /* ========== EXTERNAL FUNCTIONS ========== */

    function zap(
        address _inputToken,
        uint256 _amount,
        address _targetToken,
        bool _targetIsNative
    ) external returns (uint256 amountOut) {
        amountOut = _universalZap(
            _inputToken, //_inputToken
            _amount, //_amount
            _targetToken, //_targetToken
            msg.sender, //_recipient
            _targetIsNative
        );
    }

    /* ========== EXTERNAL FUNCTIONS ========== */

    function zapETH(address _targetToken) external payable returns (uint256 amountOut) {
        require(msg.value > 0, "Insufficient ETH");
        amountOut = _universalZapETH(
            msg.value, //_amount
            _targetToken, //_targetToken
            msg.sender //_recipient
        );
    }

    function addTaxFreeLiquidity(
        address _tokenA,
        address _tokenB,
        uint256 _amountA,
        uint256 _amountB
    ) external {
        IERC20(_tokenA).transferFrom(msg.sender, address(this), _amountA);
        IERC20(_tokenB).transferFrom(msg.sender, address(this), _amountB);

        _increaseRouterAllowance(_tokenA, _amountA);
        _increaseRouterAllowance(_tokenB, _amountB);

        ROUTER.addLiquidity(
            _tokenA,
            _tokenB,
            _amountA,
            _amountB,
            _amountA.mul(95).div(100),
            _amountB.mul(95).div(100),
            msg.sender,
            block.timestamp + 40
        );
    }

    function removeTaxFreeLiquidity(
        address _tokenA,
        address _tokenB,
        address _pair,
        uint256 _amount
    ) external {
        IERC20(_pair).transferFrom(msg.sender, address(this), _amount);

        _increaseRouterAllowance(_pair, _amount);

        (uint256 _amountA, uint256 _amountB) = ROUTER.removeLiquidity(
            _tokenA,
            _tokenB,
            _amount,
            0,
            0,
            address(this),
            block.timestamp + 40
        );

        IERC20(_tokenA).transfer(msg.sender, _amountA);
        IERC20(_tokenB).transfer(msg.sender, _amountB);
    }

    /* ========== MAIN ZAP FUNCTION ========== */

    function _zapIntoTokenTaxWrapper(
        address _inputToken,
        uint256 _amount,
        address _targetToken,
        bool _targetIsNative,
        address _recipient
    ) internal returns (uint256 amountOut) {
        //Handle token taxes - Only if not zapping into farm.
        //Zap into token.
        if (
            (address(_inputToken) == address(mainToken)) &&
            (address(_targetToken) != address(mainToken)) &&
            (address(_targetToken) != address(mainTokenLP))
        ) {
            //Calculate tax variables.
            uint256 tokenTaxRate = BBToken(_inputToken).getCurrentTaxRate();
            uint256 taxedAmount = _amount.mul(tokenTaxRate).div(10000);
            //Halve the taxed amount if the target token is an LP token.
            if (tokenType[_targetToken] == TokenType.LP) {
                taxedAmount = taxedAmount.div(2);
            }
            //Send taxes to Tax Office and handle accordingly.
            //Amend the input amount.
            _amount = _amount.sub(taxedAmount);
        }
        if (_targetIsNative == true) {
            amountOut = _zapIntoETH(_inputToken, _amount, _recipient);
        } else {
            amountOut = _zapIntoToken(_inputToken, _amount, _targetToken, _recipient);
        }
    }

    /**
        @notice Zaps in ERC20 tokens to LP tokens.
    */
    function _zapIntoETH(
        address _inputToken,
        uint256 _amount,
        address _recipient
    ) internal returns (uint256 amountOut) {
        require(tokenType[_inputToken] == TokenType.ERC20, "Error: Invalid token type");
        //Safely increase the router allowance.
        _increaseRouterAllowance(_inputToken, _amount);

        amountOut = _swapTokensForETH(
            _amount, //_amountIn,
            _inputToken, //_pathIn,
            _recipient //_recipient,
        );
    }

    /**
        @notice Zaps in ERC20 tokens to LP tokens.
    */
    function _zapIntoToken(
        address _inputToken,
        uint256 _amount,
        address _targetToken,
        address _recipient
    ) internal returns (uint256 amountOut) {
        require(tokenType[_inputToken] == TokenType.ERC20, "Error: Invalid token type");
        require(tokenType[_targetToken] != TokenType.INVALID, "Error: Invalid token type");

        //Safely increase the router allowance.
        _increaseRouterAllowance(_inputToken, _amount);

        //If target token is an LP token.
        if (tokenType[_targetToken] == TokenType.LP) {
            //Deconstruct target token.
            IPancakePair pair = IPancakePair(_targetToken);
            address token0 = pair.token0();
            address token1 = pair.token1();

            //Input token is a component of the target LP token then swap half and add liquidity.
            if (_inputToken == token0 || _inputToken == token1) {
                //Dictate which is the missing LP token.
                address missingToken = _inputToken == token0 ? token1 : token0;
                uint256 altTokenAmount = _amount.div(2);

                amountOut = _zapIntoLPFromComponentToken(
                    _inputToken, // _componentToken
                    _inputToken, // _altToken
                    _amount.sub(altTokenAmount), //_componentTokenAmount
                    altTokenAmount, //_altTokenAmount
                    missingToken, //_missingToken
                    _recipient //_recipient
                );

                //Otherwise swap the token for ETH and then add the liquidity from there.
            } else {
                uint256 ethAmount = _swapTokensForETH(
                    _amount, //_amountIn,
                    _inputToken, //_pathIn,
                    address(this) //_recipient,
                );

                //Truncate eth balance to account for tax.
                uint256 ethBalance = address(this).balance;
                ethAmount = ethAmount > ethBalance ? ethBalance : ethAmount;

                amountOut = _swapETHToLP(
                    _targetToken, //lpToken
                    ethAmount, //amount
                    _recipient //_recipient.
                );
            }
            //Otherwise swap tokens for tokens.
        } else {
            amountOut = _swapTokensForTokens(
                _amount, //_amountIn
                _inputToken, //_pathIn
                _targetToken, //_pathOut
                _recipient //_recipient
            );
        }
    }

    function _zapIntoLPFromComponentToken(
        address _componentToken,
        address _altToken,
        uint256 _componentTokenAmount,
        uint256 _altTokenAmount,
        address _missingToken,
        address _recipient
    ) internal returns (uint256 amountOut) {
        //Swap alternative token to missing token.
        _increaseRouterAllowance(_altToken, _altTokenAmount);
        uint256 _missingTokenAmount = _swapTokensForTokens(
            _altTokenAmount, //_amountIn
            _altToken, //_pathIn
            _missingToken, //_pathOut
            address(this) //_recipient
        );

        //Increase router allowances.
        _increaseRouterAllowance(_componentToken, _componentTokenAmount);
        _increaseRouterAllowance(_missingToken, _missingTokenAmount);

        //Add liquidity
        (, , amountOut) = ROUTER.addLiquidity(
            _componentToken,
            _missingToken,
            _componentTokenAmount,
            _missingTokenAmount,
            0,
            0,
            _recipient,
            block.timestamp + 40
        );

        //Emit event - Dont need to truncate as we send straight to recipient from the router.
        emit AddLiquidity(
            _componentToken,
            _missingToken,
            _componentTokenAmount,
            _missingTokenAmount,
            amountOut
        );
    }

    function _unZapIntoETH(
        address _inputToken,
        uint256 _amount,
        address _recipient
    ) internal returns (uint256 amountOut) {
        require(tokenType[_inputToken] == TokenType.LP, "Error: Invalid token type");

        //Deconstruct target token.
        IPancakePair pair = IPancakePair(_inputToken);
        address tokenA = pair.token0();
        address tokenB = pair.token1();

        //Remove Liquidity.
        _increaseRouterAllowance(_inputToken, _amount);
        (uint256 amountA, uint256 amountB) = ROUTER.removeLiquidity(
            tokenA, //tokenA
            tokenB, //tokenB
            _amount, //liquidity
            0, //amountAMin
            0, //amountBMin
            address(this), //recipient
            block.timestamp + 40 //deadline
        );

        //Swap tokenA to target token if required.
        if (tokenA != WETH) {
            amountA = _swapTokensForTokens(
                amountA, //_amountIn
                tokenA, //_pathIn
                WETH, //_pathOut
                address(this) //_recipient
            );
            IWETH(WETH).withdraw(amountA);
            TransferHelper.safeTransferETH(_recipient, amountA);
        } else {
            IWETH(WETH).withdraw(amountA);
            TransferHelper.safeTransferETH(_recipient, amountA);
        }

        //Swap tokenB to target token if required.
        if (tokenB != WETH) {
            amountB = _swapTokensForTokens(
                amountB, //_amountIn
                tokenB, //_pathIn
                WETH, //_pathOut
                address(this) //_recipient
            );
            IWETH(WETH).withdraw(amountB);
            TransferHelper.safeTransferETH(_recipient, amountB);
        } else {
            IWETH(WETH).withdraw(amountB);
            TransferHelper.safeTransferETH(_recipient, amountB);
        }

        //Add amount out.
        amountOut = amountA.add(amountB);
    }

    function _unZapIntoToken(
        address _inputToken,
        uint256 _amount,
        address _targetToken,
        address _recipient
    ) internal returns (uint256 amountOut) {
        require(tokenType[_inputToken] == TokenType.LP, "Error: Invalid token type");
        require(tokenType[_targetToken] == TokenType.ERC20, "Error: Invalid token type");

        //Deconstruct target token.
        IPancakePair pair = IPancakePair(_inputToken);
        address tokenA = pair.token0();
        address tokenB = pair.token1();

        //Remove Liquidity.
        _increaseRouterAllowance(_inputToken, _amount);
        (uint256 amountA, uint256 amountB) = ROUTER.removeLiquidity(
            tokenA, //tokenA
            tokenB, //tokenB
            _amount, //liquidity
            0, //amountAMin
            0, //amountBMin
            address(this), //recipient
            block.timestamp + 40 //deadline
        );

        //Swap tokenA to target token if required.
        if (tokenA != _targetToken) {
            amountA = _swapTokensForTokens(
                amountA, //_amountIn
                tokenA, //_pathIn
                _targetToken, //_pathOut
                _recipient //_recipient
            );
        } else {
            IERC20(_targetToken).transfer(_recipient, amountA);
        }

        //Swap tokenB to target token if required.
        if (tokenB != _targetToken) {
            amountB = _swapTokensForTokens(
                amountB, //_amountIn
                tokenB, //_pathIn
                _targetToken, //_pathOut
                _recipient //_recipient
            );
        } else {
            IERC20(_targetToken).transfer(_recipient, amountB);
        }

        //Add amount out.
        amountOut = amountA.add(amountB);
    }

    function _unZapIntoLP(
        address _inputToken,
        uint256 _amount,
        address _targetToken,
        address _recipient
    ) internal returns (uint256 amountOut) {
        require(tokenType[_inputToken] == TokenType.LP, "Error: Invalid token type");
        require(tokenType[_targetToken] == TokenType.LP, "Error: Invalid token type");

        //Deconstruct target token.
        IPancakePair pair = IPancakePair(_inputToken);
        address inputTokenA = pair.token0();
        address inputTokenB = pair.token1();

        //Remove Liquidity.
        _increaseRouterAllowance(_inputToken, _amount);
        (uint256 amountA, uint256 amountB) = ROUTER.removeLiquidity(
            inputTokenA, //tokenA
            inputTokenB, //tokenB
            _amount, //liquidity
            0, //amountAMin
            0, //amountBMin
            address(this), //recipient
            block.timestamp + 40 //deadline
        );

        //Get output token components.
        pair = IPancakePair(_targetToken);
        address outputTokenA = pair.token0();
        address outputTokenB = pair.token1();

        //If input token A is already a component.
        if (inputTokenA == outputTokenA || inputTokenA == outputTokenB) {
            //Dictate which is the missing LP token.
            address missingToken = inputTokenA == outputTokenA ? outputTokenB : outputTokenA;
            amountOut = _zapIntoLPFromComponentToken(
                inputTokenA, //_componentToken,
                inputTokenB, //_altToken,
                amountA, //_componentTokenAmount,
                amountB, //_altTokenAmount,
                missingToken, //_missingToken,
                _recipient
            );
            //If input token A is already a component.
        } else if (inputTokenB == outputTokenA || inputTokenB == outputTokenB) {
            //Dictate which is the missing LP token.
            address missingToken = inputTokenB == outputTokenA ? outputTokenB : outputTokenA;
            amountOut = _zapIntoLPFromComponentToken(
                inputTokenB, //_componentToken,
                inputTokenA, //_altToken,
                amountB, //_componentTokenAmount,
                amountA, //_altTokenAmount,
                missingToken, //_missingToken,
                _recipient
            );
            //Otherwise swap both tokens to ETH and then convert to LP.
        } else {
            //Swap both tokens to ETH.
            uint256 ethAmountA = _swapTokensForETH(
                amountA, //_amountIn,
                inputTokenA, //_pathIn,
                address(this) //_recipient,
            );
            uint256 ethAmountB = _swapTokensForETH(
                amountB, //_amountIn,
                inputTokenB, //_pathIn,
                address(this) //_recipient,
            );

            //Convert eth to LP.
            amountOut = _swapETHToLP(
                _targetToken, //lpToken
                ethAmountA.add(ethAmountB), //amount
                _recipient //_recipient.
            );
        }
    }

    function universalZapForCompound(
        address _inputToken,
        uint256 _amount,
        address _targetToken,
        address _recipient
    ) external returns (uint256 amountOut) {
        require(tokenType[_targetToken] != TokenType.INVALID, "Error: Invalid token type");
        //Transfer token into contract.
        
        //Exit early if no zap required.
        if (_inputToken == _targetToken) {
            if (_recipient != address(this)) {
                IERC20(_inputToken).transfer(_recipient, _amount);
            }
            return _amount;
        }

        IERC20(_inputToken).transferFrom(msg.sender, address(this), _amount);
        amountOut = _zapIntoTokenTaxWrapper(
            _inputToken,
            _amount,
            _targetToken,
            false,
            _recipient
        );
        //Truncate to target token balance.
        uint256 targetTokenBalance = IERC20(_targetToken).balanceOf(_recipient);
        amountOut = amountOut > targetTokenBalance ? targetTokenBalance : amountOut;
    }

    function _universalZap(
        address _inputToken,
        uint256 _amount,
        address _targetToken,
        address _recipient,
        bool _targetIsNative
    ) internal returns (uint256 amountOut) {
        require(tokenType[_inputToken] != TokenType.INVALID, "Error: Invalid token type");
        require(tokenType[_targetToken] != TokenType.INVALID, "Error: Invalid token type");

        //Transfer token into contract.
        IERC20(_inputToken).transferFrom(msg.sender, address(this), _amount);

        //Exit early if no zap required.
        if (_inputToken == _targetToken) {
            if (_recipient != address(this)) {
                IERC20(_inputToken).transfer(_recipient, _amount);
            }
            return _amount;
        }

        //Zap into token.
        if (tokenType[_inputToken] == TokenType.ERC20) {
            if (_inputToken == WETH && _targetIsNative == true) {
                IWETH(WETH).withdraw(_amount);
                TransferHelper.safeTransferETH(_recipient, _amount);
            } else {
                amountOut = _zapIntoTokenTaxWrapper(
                    _inputToken,
                    _amount,
                    _targetToken,
                    _targetIsNative,
                    _recipient
                );
            }
        } else if (tokenType[_targetToken] == TokenType.ERC20) {
            if (_targetIsNative) {
                amountOut = _unZapIntoETH(_inputToken, _amount, _recipient);
            } else {
                amountOut = _unZapIntoToken(_inputToken, _amount, _targetToken, _recipient);
            }
        } else {
            amountOut = _unZapIntoLP(_inputToken, _amount, _targetToken, _recipient);
        }

        //Truncate to target token balance.
        uint256 targetTokenBalance = IERC20(_targetToken).balanceOf(_recipient);
        amountOut = amountOut > targetTokenBalance ? targetTokenBalance : amountOut;
    }

    function _universalZapETH(
        uint256 _amount,
        address _targetToken,
        address _recipient
    ) internal returns (uint256 amountOut) {
        require(tokenType[_targetToken] != TokenType.INVALID, "Error: Invalid token type");
        //Zap into token.
        if (tokenType[_targetToken] == TokenType.ERC20) {
            if (_targetToken == WETH) {
                IWETH(WETH).deposit{value: _amount}();
                IERC20(WETH).transfer(_recipient, _amount);
            } else {
                amountOut = _swapETHForTokens(_amount, _targetToken, _recipient);
            }
        } else {
            amountOut = _swapETHToLP(_targetToken, _amount, _recipient);
        }

        //Truncate to target token balance.
        uint256 targetTokenBalance = IERC20(_targetToken).balanceOf(_recipient);
        amountOut = amountOut > targetTokenBalance ? targetTokenBalance : amountOut;
    }

    /* ========== Private Functions ========== */

    function _swapETHToLP(
        address _lpToken,
        uint256 _amount,
        address _recipient
    ) internal returns (uint256 amountOut) {
        //If target token is not an LP then perform single swap.
        if (tokenType[_lpToken] == TokenType.LP) {
            //Deconstruct LP token.
            IPancakePair pair = IPancakePair(_lpToken);
            address token0 = pair.token0();
            address token1 = pair.token1();

            //If either of the tokens are WETH then swap half of the EVMOS balance.
            if (token0 == WETH || token1 == WETH) {
                address altToken = token0 == WETH ? token1 : token0;
                uint256 swapValue = _amount.div(2);

                uint256 altTokenAmount = _swapETHForTokens(
                    swapValue, //_amountIn
                    altToken, //_pathOut
                    address(this) //_recipient
                );

                _increaseRouterAllowance(altToken, altTokenAmount);

                (, , amountOut) = ROUTER.addLiquidityETH{value: _amount.sub(swapValue)}(
                    altToken,
                    altTokenAmount,
                    0,
                    0,
                    _recipient,
                    block.timestamp + 40
                );
                emit AddLiquidity(
                    WETH,
                    altToken,
                    _amount.sub(swapValue),
                    altTokenAmount,
                    amountOut
                );

                //Otherwise perform 2 swaps & add liquidity.
            } else {
                uint256 swapValue = _amount.div(2);
                uint256 token0Amount = _swapETHForTokens(
                    swapValue, //_amountIn
                    token0, //_pathOut
                    address(this) //_recipient
                );
                uint256 token1Amount = _swapETHForTokens(
                    _amount.sub(swapValue), //_amountIn
                    token1, //_pathOut
                    address(this) //_recipient
                );

                _increaseRouterAllowance(token0, token0Amount);
                _increaseRouterAllowance(token1, token1Amount);

                (, , amountOut) = ROUTER.addLiquidity(
                    token0,
                    token1,
                    token0Amount,
                    token1Amount,
                    0,
                    0,
                    _recipient,
                    block.timestamp + 40
                );
                emit AddLiquidity(token0, token1, token0Amount, token1Amount, amountOut);
            }
        }
    }

    /* ========== SWAP FUNCTIONS ========== */

    function _increaseRouterAllowance(address _token, uint256 _amount) private {
        IERC20(_token).safeIncreaseAllowance(address(ROUTER), _amount);
    }

    function _setSwapPath(
        address _token0,
        address _token1,
        address[] memory _path
    ) internal virtual {
        require(_path.length > 1, "Error: Path is not long enough.");
        require(
            _path[0] == _token0 && _path[_path.length - 1] == _token1,
            "Error: Endpoints of path are incorrect."
        );
        swapPath[_token0][_token1] = _path;

        //Set inverse path.
        uint256 pathLength = _path.length;
        address[] memory invPath = new address[](pathLength);
        for (uint256 i = 0; i < pathLength; i++) {
            invPath[i] = _path[pathLength - 1 - i];
        }
        swapPath[_token1][_token0] = invPath;
    }

    function setSwapPath(
        address _token0,
        address _token1,
        address[] calldata _path
    ) external virtual onlyOwner {
        _setSwapPath(_token0, _token1, _path);
    }

    /**
        @notice Swaps Tokens for Tokens Safely. - Is public to allow a static call.
    */
    function _swapTokensForTokens(
        uint256 _amountIn,
        address _pathIn,
        address _pathOut,
        address _recipient
    ) internal returns (uint256 _outputAmount) {
        //Extract swap path.
        address[] memory path = swapPath[_pathIn][_pathOut];
        if (path.length == 0) {
            path = new address[](2);
            path[0] = _pathIn;
            path[1] = _pathOut;
        }

        //Increase allowance and swap.
        if (_amountIn > 0) {
            _increaseRouterAllowance(_pathIn, _amountIn);

            uint256[] memory amounts = ROUTER.swapExactTokensForTokens(
                _amountIn,
                0,
                path,
                _recipient,
                block.timestamp + 40
            );
            _outputAmount = amounts[amounts.length - 1];
        }

        emit SwapTokens(_pathIn, _pathOut, _amountIn, _outputAmount);
    }

    /**
        @notice Swaps Tokens for 'ETH' safely. 
    */
    function _swapTokensForETH(
        uint256 _amountIn,
        address _pathIn,
        address _recipient
    ) internal returns (uint256 _outputAmount) {
        //Set output of the path.
        address _pathOut = WETH;

        //Extract swap path.
        address[] memory path = swapPath[_pathIn][_pathOut];
        if (path.length == 0) {
            path = new address[](2);
            path[0] = _pathIn;
            path[1] = _pathOut;
        }

        //Increase allowance and swap.
        if (_amountIn > 0) {
            _increaseRouterAllowance(_pathIn, _amountIn);

            uint256[] memory amounts = ROUTER.swapExactTokensForETH(
                _amountIn,
                0,
                path,
                _recipient,
                block.timestamp + 40
            );
            _outputAmount = amounts[amounts.length - 1];
        }

        emit SwapTokens(_pathIn, _pathOut, _amountIn, _outputAmount);
    }

    /**
        @notice Swaps 'ETH' for Tokens safely. 
    */
    function _swapETHForTokens(
        uint256 _amountIn,
        address _pathOut,
        address _recipient
    ) internal returns (uint256 _outputAmount) {
        //Set output of the path.
        address _pathIn = WETH;

        //Extract swap path.
        address[] memory path = swapPath[_pathIn][_pathOut];
        if (path.length == 0) {
            path = new address[](2);
            path[0] = _pathIn;
            path[1] = _pathOut;
        }

        //Increase allowance and swap.
        if (_amountIn > 0) {
            uint256[] memory amounts = ROUTER.swapExactETHForTokens{value: _amountIn}(
                0,
                path,
                _recipient,
                block.timestamp + 40
            );
            _outputAmount = amounts[amounts.length - 1];
        }

        emit SwapTokens(_pathIn, _pathOut, _amountIn, _outputAmount);
    }

    /* ========== EXTERNAL SWAP FUNCTIONS ========== */

    function swapTokensForTokens(
        uint256 _amountIn,
        address _pathIn,
        address _pathOut,
        address _recipient
    ) external onlyOperator returns (uint256 _outputAmount) {
        IERC20(_pathIn).transferFrom(msg.sender, address(this), _amountIn);
        _outputAmount = _swapTokensForTokens(_amountIn, _pathIn, _pathOut, _recipient);
    }

    function swapETHForTokens(
        uint256 _amountIn,
        address _pathOut,
        address _recipient
    ) external payable onlyOperator returns (uint256 _outputAmount) {
        require(msg.value > _amountIn, "Zap: Not enough ether sent in for the swap");
        _outputAmount = _swapETHForTokens(_amountIn, _pathOut, _recipient);
    }

    function swapTokensForETH(
        uint256 _amountIn,
        address _pathIn,
        address _recipient
    ) external onlyOperator returns (uint256 _outputAmount) {
        IERC20(_pathIn).transferFrom(msg.sender, address(this), _amountIn);
        _outputAmount = _swapTokensForETH(_amountIn, _pathIn, _recipient);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /**
        @notice Sets the token type of an address.
    */
    function setTokenType(address _token, uint8 _type) public onlyOwner {
        tokenType[_token] = TokenType(_type);
    }

    function setTokensType(address[] memory _tokens, uint8 _type) external onlyOperator {
        for (uint8 idx = 0; idx < _tokens.length; ++idx) {
            tokenType[_tokens[idx]] = TokenType(_type);
        }
    }

    function setTokensTypes(address[] memory _tokens, uint8[] memory _types) external onlyOperator {
        require(_tokens.length == _types.length, "Error: Tokens and Types lengths not equal");
        for (uint8 idx = 0; idx < _tokens.length; ++idx) {
            tokenType[_tokens[idx]] = TokenType(_types[idx]);
        }
    }

    function withdraw(address token) external onlyOwner {
        if (token == address(0)) {
            (bool callSuccess, ) = payable(msg.sender).call{value: address(this).balance}("");
            require(callSuccess, "Call failed");
        }
        IERC20(token).transfer(owner(), IERC20(token).balanceOf(address(this)));
    }
}
