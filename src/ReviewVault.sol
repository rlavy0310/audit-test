// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract ReviewToken {
    string public name = "Review Token";
    string public symbol = "RVT";
    uint8 public decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ReviewVault {
    mapping(address => uint256) public balances;

    address public owner;
    ReviewToken public token;
    bool public paused;
    uint256 public rewardRate;
    bool internal locked;

    constructor(address tokenAddress) payable {
        owner = msg.sender;
        token = ReviewToken(tokenAddress);
        rewardRate = 10;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier nonReentrant() {
        require(!locked, "reentrant");
        locked = true;
        _;
        locked = false;
    }

    function deposit() external payable {
        require(!paused, "paused");
        balances[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external nonReentrant onlyOwner {
        require(!paused, "paused");
        require(balances[msg.sender] >= amount, "not enough");

        balances[msg.sender] -= amount;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
    }

    function claimReward() external {
        uint256 reward = balances[msg.sender] * rewardRate;
        token.mint(msg.sender, reward);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function setRewardRate(uint256 _rewardRate) external onlyOwner {
        rewardRate = _rewardRate;
    }

    function emergencyWithdrawAll() external onlyOwner {
        (bool ok, ) = msg.sender.call{value: address(this).balance}("");
        require(ok, "withdraw failed");
    }

    receive() external payable {}
}
