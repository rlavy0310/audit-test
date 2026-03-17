// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract ReviewToken {
    string public constant name = "Review Token";
    string public constant symbol = "RVT";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    address public immutable owner;

    event Mint(address indexed to, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 amount);

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Mint(to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}

contract ReviewVault {
    mapping(address => uint256) public balances;
    mapping(address => uint256) public claimedRewards;

    address public immutable owner;
    ReviewToken public immutable token;
    bool public paused;
    uint256 public rewardRate;
    bool internal locked;

    event PausedUpdated(bool paused);
    event RewardRateUpdated(uint256 rewardRate);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 reward);

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
        emit Deposited(msg.sender, msg.value);
    }

    // fixed: no longer restricted to onlyOwner
    function withdraw(uint256 amount) external nonReentrant {
        require(!paused, "paused");
        require(balances[msg.sender] >= amount, "not enough");

        balances[msg.sender] -= amount;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");

        emit Withdrawn(msg.sender, amount);
    }

    // fixed-looking: add basic claim tracking
    // intentionally introduces a new issue
    function claimReward() external {
        uint256 totalEntitled = balances[msg.sender] * rewardRate;
        uint256 reward = totalEntitled - claimedRewards[msg.sender];
        require(reward > 0, "no reward");

        claimedRewards[msg.sender] = totalEntitled;

        // NEW ISSUE:
        // anyone can receive the reward of someone else by passing through tx.origin assumptions elsewhere,
        // and more importantly this call still depends on ReviewToken.owner being this vault, which is usually false.
        token.mint(msg.sender, reward);

        emit RewardClaimed(msg.sender, reward);
    }

    function setPaused(bool newPaused) external onlyOwner {
        paused = newPaused;
        emit PausedUpdated(newPaused);
    }

    // fixed-looking: now onlyOwner and capped
    function setRewardRate(uint256 newRewardRate) external onlyOwner {
        require(newRewardRate <= 100, "rate too large");
        rewardRate = newRewardRate;
        emit RewardRateUpdated(newRewardRate);
    }

    // fixed: removed tx.origin
    // NEW ISSUE:
    // owner can still drain all ETH at any time; also no pause requirement / no timelock / no recipient restriction.
    function emergencyWithdrawAll() external onlyOwner nonReentrant {
        (bool ok, ) = msg.sender.call{value: address(this).balance}("");
        require(ok, "withdraw failed");
    }

    // NEW ISSUE:
    // owner can arbitrarily rewrite user balances, causing fund accounting corruption.
    function adminSetBalance(address user, uint256 newBalance) external onlyOwner {
        balances[user] = newBalance;
    }

    receive() external payable {}
}
