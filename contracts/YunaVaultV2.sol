// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract YunaVaultV2 is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable lpToken;
    IERC20 public immutable rewardToken;
    address public immutable protocol;
    uint256 public immutable rewardPerBlock;

    address public router;

    uint256 public constant CALLER_FEE_BP = 50;
    uint256 public constant BP_DENOM = 10000;

    uint256 public lastRewardBlock;
    uint256 public totalXP;

    struct User {
        uint256 balance;
        uint256 lastUpdateBlock;
        uint256 xp;
    }

    mapping(address => User) public users;
    address[] public participants;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event ClaimAll(uint256 totalDistributed, uint256 callerReward);
    event RouterSet(address router);

    modifier onlyRouter() {
        require(msg.sender == router, "not router");
        _;
    }

    constructor(
        address _lpToken,
        address _rewardToken,
        address _protocol
    ) Ownable(msg.sender) {
        lpToken = IERC20(_lpToken);
        rewardToken = IERC20(_rewardToken);
        protocol = _protocol;

        uint8 decimals = IERC20Metadata(_rewardToken).decimals();
        uint256 blocksPerYear = 52_560; // 10 min blocks
        rewardPerBlock = (200_000_000 * (10 ** decimals)) / blocksPerYear;

        lastRewardBlock = block.number;
    }

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "zero address");
        router = _router;
        emit RouterSet(_router);
    }

    function _updateUserXP(address userAddr) internal {
        User storage u = users[userAddr];

        if (u.lastUpdateBlock == 0) {
            u.lastUpdateBlock = block.number;
            return;
        }

        uint256 blocks = block.number - u.lastUpdateBlock;
        if (blocks > 0 && u.balance > 0) {
            uint256 gainedXP = blocks * u.balance;
            u.xp += gainedXP;
            totalXP += gainedXP;
        }

        u.lastUpdateBlock = block.number;
    }

    function deposit(uint256 amount) external nonReentrant {
        _depositFor(msg.sender, msg.sender, amount);
    }

    function depositFor(address user, uint256 amount)
        external
        nonReentrant
        onlyRouter
    {
        _depositFor(msg.sender, user, amount);
    }

    function _depositFor(address from, address user, uint256 amount) internal {
        require(amount > 0, "zero deposit");

        _updateUserXP(user);

        lpToken.safeTransferFrom(from, address(this), amount);

        User storage u = users[user];
        if (u.balance == 0) participants.push(user);
        u.balance += amount;

        emit Deposited(user, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        User storage u = users[msg.sender];
        require(amount > 0 && amount <= u.balance, "invalid amount");

        _updateUserXP(msg.sender);

        u.balance -= amount;

        lpToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    function withdrawAll() external nonReentrant {
        User storage u = users[msg.sender];
        uint256 amount = u.balance;
        require(amount > 0, "nothing to withdraw");

        _updateUserXP(msg.sender);

        u.balance = 0;

        lpToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    function claimAll() external nonReentrant {
        uint256 blocks = block.number - lastRewardBlock;
        if (blocks == 0 || totalXP == 0) return;

        uint256 pool = blocks * rewardPerBlock;

        for (uint256 i = 0; i < participants.length; i++) {
            User storage u = users[participants[i]];
            if (u.balance == 0) continue;

            uint256 gainedXP = (block.number - u.lastUpdateBlock) * u.balance;
            u.xp += gainedXP;
            totalXP += gainedXP;
            u.lastUpdateBlock = block.number;
        }

        uint256 callerReward = (pool * CALLER_FEE_BP) / BP_DENOM;
        if (callerReward > 0) {
            rewardToken.safeTransfer(msg.sender, callerReward);
        }

        uint256 distributable = pool - callerReward;

        for (uint256 i = 0; i < participants.length; i++) {
            address user = participants[i];
            User storage u = users[user];
            if (u.xp == 0) continue;

            uint256 reward = (distributable * u.xp) / totalXP;
            if (reward > 0) rewardToken.safeTransfer(user, reward);

            u.xp = 0;
        }

        totalXP = 0;
        lastRewardBlock = block.number;

        emit ClaimAll(distributable, callerReward);
    }

    function claimableReward(address userAddr) external view returns (uint256) {
        User storage u = users[userAddr];
        if (u.balance == 0) return 0;

        uint256 blocks = block.number - lastRewardBlock;
        if (blocks == 0) return 0;

        uint256 userXP = u.xp;
        if (u.lastUpdateBlock > 0) {
            userXP += (block.number - u.lastUpdateBlock) * u.balance;
        }

        if (userXP == 0) return 0;

        uint256 simulatedTotalXP = totalXP + userXP;
        uint256 pool = blocks * rewardPerBlock;
        uint256 callerFee = (pool * CALLER_FEE_BP) / BP_DENOM;
        uint256 distributable = pool - callerFee;

        return (distributable * userXP) / simulatedTotalXP;
    }

    function remainingRewardPool() external view returns (uint256) {
        uint256 blocks = block.number - lastRewardBlock;
        if (blocks == 0) return 0;
        return blocks * rewardPerBlock;
    }

    function totalLPLocked() external view returns (uint256) {
        return lpToken.balanceOf(address(this));
    }

    function participantCount() external view returns (uint256) {
        return participants.length;
    }

    function getUserXP(address userAddr) external view returns (uint256) {
        User storage u = users[userAddr];
        uint256 xp = u.xp;

        if (u.lastUpdateBlock > 0) {
            xp += (block.number - u.lastUpdateBlock) * u.balance;
        }

        return xp;
    }
}
