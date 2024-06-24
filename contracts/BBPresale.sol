// SPDX-License-Identifier: UNLICENSED



pragma solidity ^0.8.15;
import "./PriceConverter.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract BBPresale is ReentrancyGuard {
    using PriceConverter for uint256;
    // IERC20(); // localhost

    IERC20 public WILD; // mainnet    to be adjusted
    // IERC20(); // localhost

    address public owner;
    mapping(address => uint256) public user_deposits;
    mapping(address => uint256) public user_withdraw_amount;
    mapping(address => uint256) public user_withdraw_timestamp;
    mapping(address => uint256) public WILDOwned;

    uint256 public finishedTimestamp;
    uint256 public total_deposited;
    uint256 public vestingPeriod = 20 days;

    uint256 public presalePriceOfToken = 12;
    uint256 public MAX_AMOUNT = 250 * 1e18;

    bool public enabled = true;
    bool public sale_finalized = false;
    event Received(address, uint);

    // CUSTOM ERRORS

    error SaleIsNotActive();
    error ZeroAddress();
    error SaleIsNotFinalizedYet();

    constructor(address _wild) {
        WILD = IERC20(_wild);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the Owner!");
        _;
    }

    function getUserDeposits(address user) public view returns (uint256) {
        return user_deposits[user];
    }

    function getWILDOwned(address user) public view returns (uint256) {
        return WILDOwned[user];
    }

    function getClaimedAmount(address user) public view returns (uint256) {
        return user_withdraw_amount[user];
    }

    function getTotalRaised() external view returns (uint256) {
        return total_deposited;
    }

    function buyWILD() public payable nonReentrant {
        if (!enabled || sale_finalized) revert SaleIsNotActive();
        require(
            WILDOwned[msg.sender] + msg.value.getConversionRate() / presalePriceOfToken <=
                MAX_AMOUNT,
            "Exceed Max Amount"
        );
        user_deposits[msg.sender] += msg.value;
        WILDOwned[msg.sender] += msg.value.getConversionRate() / presalePriceOfToken;
        total_deposited += msg.value;
    }

    function withdrawWILD() external nonReentrant {
        if (!sale_finalized) revert SaleIsNotFinalizedYet();

        uint256 total_to_send = WILDOwned[msg.sender];
        require(total_to_send > 0, "Insufficient WILD owned by user");

        if (user_withdraw_timestamp[msg.sender] < finishedTimestamp) {
            user_withdraw_timestamp[msg.sender] = finishedTimestamp;
        }

        require(
            WILDOwned[msg.sender] > user_withdraw_amount[msg.sender],
            "you already claimed all tokens"
        );

        require(
            block.timestamp - user_withdraw_timestamp[msg.sender] >= 1 days,
            "You cannot withdraw WILD token yet"
        );

        uint256 availableAmount = getAmountToWithdraw(msg.sender);

        uint256 contractBalance = WILD.balanceOf(address(this));
        require(contractBalance >= availableAmount, "Insufficient contract balance");

        user_withdraw_timestamp[msg.sender] = block.timestamp;
        user_withdraw_amount[msg.sender] += availableAmount;
        WILD.transfer(msg.sender, availableAmount);
    }

    function getAmountToWithdraw(address _user) public view returns (uint256) {
        if (!sale_finalized) return 0;
        if (user_withdraw_timestamp[msg.sender] == 0) return 0;
        if (block.timestamp - user_withdraw_timestamp[msg.sender] < 1 days) {
            return 0;
        } else {
            uint256 rate = ((block.timestamp - user_withdraw_timestamp[_user]) * 100) /
                vestingPeriod;

            uint256 amount = (WILDOwned[_user] * rate) / 100;
            return amount;
        }
    }

    function setEnabled(bool _enabled) external onlyOwner {
        enabled = _enabled;
    }

    function finalizeSale() external onlyOwner {
        sale_finalized = true;
        finishedTimestamp = block.timestamp;
    }

    function changeOwner(address _address) external onlyOwner {
        if (_address == address(0)) revert ZeroAddress();
        owner = _address;
    }

    function setWILDAddress(IERC20 _WILD) public onlyOwner {
        WILD = _WILD;
    }

    function setPrice(uint256 _newPrice) public onlyOwner {
        presalePriceOfToken = _newPrice;
    }

    function withdraw() external onlyOwner {
        (bool callSuccess, ) = payable(msg.sender).call{value: address(this).balance}("");
        require(callSuccess, "Call failed");
    }

    function withdrawExtraToken(address _token) external onlyOwner {
        IERC20(_token).transfer(owner, IERC20(_token).balanceOf(address(this)));
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
}
