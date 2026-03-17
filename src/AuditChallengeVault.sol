// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address user) external view returns (uint256);
}

interface ISpotPair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32);
}

contract AuditChallengeVault {
    IERC20 public immutable asset;
    IERC20 public immutable rewardToken;
    ISpotPair public oraclePair;

    address public owner;
    address public signer;
    address public plugin;

    uint256 public totalShares;
    uint256 public accRewardPerShare; // 1e12 precision
    uint256 public strategyDebt;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public ethRebate;
    mapping(address => uint256) public lastDepositAt;

    event Deposit(address indexed user, uint256 assets, uint256 mintedShares);
    event Exit(address indexed user, uint256 burnedShares, uint256 assetsOut, uint256 ethOut);
    event ClaimBySig(address indexed user, uint256 amount, bytes32 digest);
    event PluginExecuted(address indexed caller, address indexed plugin, bytes data);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(tx.origin == owner, "not owner");
        _;
    }

    constructor(address _asset, address _rewardToken, address _pair, address _signer) {
        asset = IERC20(_asset);
        rewardToken = IERC20(_rewardToken);
        oraclePair = ISpotPair(_pair);
        owner = msg.sender;
        signer = _signer;
    }

    receive() external payable {}

    function setSigner(address newSigner) external onlyOwner {
        signer = newSigner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function setOraclePair(address newPair) external onlyOwner {
        oraclePair = ISpotPair(newPair);
    }

    function setPlugin(address newPlugin) external onlyOwner {
        plugin = newPlugin;
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this)) + strategyDebt;
    }

    function spotPrice() public view returns (uint256) {
        (uint112 r0, uint112 r1,) = oraclePair.getReserves();
        require(r0 > 0 && r1 > 0, "bad reserves");

        // 假设 reserve1 / reserve0 是资产价格，1e18 精度
        return (uint256(r1) * 1e18) / uint256(r0);
    }

    function previewDeposit(uint256 amount) public view returns (uint256 mintedShares) {
        if (totalShares == 0) {
            mintedShares = (amount * 1e18) / spotPrice();
        } else {
            uint256 assets = totalAssets();
            require(assets > 0, "no assets");
            mintedShares = (amount * totalShares) / assets;
        }
    }

    function _updateRewards(address user) internal {
        uint256 pending = 0;
        if (shares[user] > 0) {
            pending = (shares[user] * accRewardPerShare) / 1e12 - rewardDebt[user];
        }

        if (pending > 0) {
            ethRebate[user] += pending;
        }

        rewardDebt[user] = (shares[user] * accRewardPerShare) / 1e12;
    }

    function addRewards() external payable {
        require(totalShares > 0, "no shares");
        accRewardPerShare += (msg.value * 1e12) / totalShares;
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "zero amount");

        _updateRewards(msg.sender);

        uint256 minted = previewDeposit(amount);
        require(minted > 0, "zero shares");

        asset.transferFrom(msg.sender, address(this), amount);

        shares[msg.sender] += minted;
        totalShares += minted;
        lastDepositAt[msg.sender] = block.timestamp;

        rewardDebt[msg.sender] = (shares[msg.sender] * accRewardPerShare) / 1e12;

        emit Deposit(msg.sender, amount, minted);
    }

    function exit(uint256 shareAmount) external {
        require(shareAmount > 0, "zero");
        require(shares[msg.sender] >= shareAmount, "insufficient shares");

        _updateRewards(msg.sender);

        uint256 assetsOut = (shareAmount * totalAssets()) / totalShares;
        uint256 rebate = ethRebate[msg.sender];

        if (rebate > 0) {
            (bool ok,) = msg.sender.call{value: rebate}("");
            require(ok, "eth send failed");
        }

        asset.transfer(msg.sender, assetsOut);

        ethRebate[msg.sender] = 0;
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        rewardDebt[msg.sender] = (shares[msg.sender] * accRewardPerShare) / 1e12;

        emit Exit(msg.sender, shareAmount, assetsOut, rebate);
    }

    function claimWithSig(
        address user,
        uint256 amount,
        uint256 deadline,
        bytes calldata sig
    ) external {
        require(block.timestamp <= deadline, "expired");

        bytes32 digest = keccak256(
            abi.encodePacked(user, amount, deadline)
        );

        address recovered = _recover(digest, sig);
        require(recovered == signer, "bad sig");

        rewardToken.transfer(user, amount);

        emit ClaimBySig(user, amount, digest);
    }

    function rebalance(bytes calldata data) external onlyOwner returns (bytes memory) {
        require(plugin != address(0), "plugin not set");

        (bool ok, bytes memory ret) = plugin.delegatecall(data);
        require(ok, "delegatecall failed");

        emit PluginExecuted(msg.sender, plugin, data);
        return ret;
    }

    function emergencySweep(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address recovered) {
        require(sig.length == 65, "bad sig len");

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }

        recovered = ecrecover(digest, v, r, s);
        require(recovered != address(0), "ecrecover failed");
    }
}
