// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address user) external view returns (uint256);
}

interface ISpotPair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract AuditChallengeVault {
    IERC20 public immutable asset;
    IERC20 public immutable rewardToken;
    ISpotPair public oraclePair;

    address public owner;
    address public signer;
    address public plugin;

    uint256 public totalShares;
    uint256 public accRewardPerShare;
    uint256 public strategyDebt;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public ethRebate;
    mapping(address => uint256) public lastDepositAt;
    mapping(bytes32 => bool) public usedDigests;

    bool private locked;

    event Deposit(address indexed user, uint256 assets, uint256 mintedShares);
    event Exit(address indexed user, uint256 burnedShares, uint256 assetsOut, uint256 ethOut);
    event ClaimBySig(address indexed user, uint256 amount, bytes32 digest);
    event PluginExecuted(address indexed caller, address indexed plugin, bytes data);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event SignerChanged(address indexed oldSigner, address indexed newSigner);
    event PluginChanged(address indexed oldPlugin, address indexed newPlugin);
    event OraclePairChanged(address indexed oldPair, address indexed newPair);

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

    constructor(address _asset, address _rewardToken, address _pair, address _signer) {
        require(_asset != address(0), "asset zero");
        require(_rewardToken != address(0), "reward zero");
        require(_pair != address(0), "pair zero");
        require(_signer != address(0), "signer zero");

        asset = IERC20(_asset);
        rewardToken = IERC20(_rewardToken);
        oraclePair = ISpotPair(_pair);
        owner = msg.sender;
        signer = _signer;
    }

    receive() external payable {}

    function setSigner(address newSigner) external onlyOwner {
        require(newSigner != address(0), "zero");
        emit SignerChanged(signer, newSigner);
        signer = newSigner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function setOraclePair(address newPair) external onlyOwner {
        require(newPair != address(0), "zero");
        emit OraclePairChanged(address(oraclePair), newPair);
        oraclePair = ISpotPair(newPair);
    }

    function setPlugin(address newPlugin) external onlyOwner {
        emit PluginChanged(plugin, newPlugin);
        plugin = newPlugin;
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this)) + strategyDebt;
    }

    function spotPrice() public view returns (uint256) {
        (uint112 r0, uint112 r1, ) = oraclePair.getReserves();
        require(r0 > 0 && r1 > 0, "bad reserves");
        return (uint256(r1) * 1e18) / uint256(r0);
    }

    function previewDeposit(uint256 amount) public view returns (uint256 mintedShares) {
        uint256 assets = totalAssets();

        if (totalShares == 0) {
            mintedShares = amount;
        } else {
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

    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");

        _updateRewards(msg.sender);

        uint256 minted = previewDeposit(amount);
        require(minted > 0, "zero shares");

        require(asset.transferFrom(msg.sender, address(this), amount), "transferFrom failed");

        shares[msg.sender] += minted;
        totalShares += minted;
        lastDepositAt[msg.sender] = block.timestamp;
        rewardDebt[msg.sender] = (shares[msg.sender] * accRewardPerShare) / 1e12;

        emit Deposit(msg.sender, amount, minted);
    }

    function exit(uint256 shareAmount) external nonReentrant {
        require(shareAmount > 0, "zero");
        require(shares[msg.sender] >= shareAmount, "insufficient shares");

        _updateRewards(msg.sender);

        uint256 assetsOut = (shareAmount * totalAssets()) / totalShares;
        uint256 rebate = ethRebate[msg.sender];

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        ethRebate[msg.sender] = 0;
        rewardDebt[msg.sender] = (shares[msg.sender] * accRewardPerShare) / 1e12;

        require(asset.transfer(msg.sender, assetsOut), "transfer failed");

        if (rebate > 0) {
            (bool ok, ) = payable(msg.sender).call{value: rebate}("");
            require(ok, "eth send failed");
        }

        emit Exit(msg.sender, shareAmount, assetsOut, rebate);
    }

    function claimWithSig(
        address user,
        uint256 amount,
        uint256 deadline,
        bytes calldata sig
    ) external nonReentrant {
        require(user != address(0), "user zero");
        require(block.timestamp <= deadline, "expired");

        bytes32 digest = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                user,
                amount,
                deadline
            )
        );

        require(!usedDigests[digest], "digest used");

        address recovered = _recover(digest, sig);
        require(recovered == signer, "bad sig");

        usedDigests[digest] = true;

        require(rewardToken.transfer(user, amount), "reward transfer failed");

        emit ClaimBySig(user, amount, digest);
    }

    function rebalance(bytes calldata data) external onlyOwner nonReentrant returns (bytes memory) {
        require(plugin != address(0), "plugin not set");

        (bool ok, bytes memory ret) = plugin.call(data);
        require(ok, "plugin call failed");

        emit PluginExecuted(msg.sender, plugin, data);
        return ret;
    }

    function emergencySweep(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(token != address(0), "token zero");
        require(to != address(0), "to zero");
        require(IERC20(token).transfer(to, amount), "sweep failed");
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

        require(v == 27 || v == 28, "bad v");
        recovered = ecrecover(digest, v, r, s);
        require(recovered != address(0), "ecrecover failed");
    }
}
