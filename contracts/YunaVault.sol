// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract YunaVault is ReentrancyGuard {
    struct Position {
        address user;
        address token;
        uint256 amount;
        uint256 startBlock;
        uint256 endBlock;
        bool claimed;
    }

    address public protocol;

    mapping(address => uint256[]) public activePositions;
    mapping(address => uint256[]) public historyPositions;

    Position[] public positions;

    constructor(address _protocol) {
        protocol = _protocol;
    }

    function stake(address token, uint256 amount, uint256 blocksToStake) external nonReentrant {
        require(amount > 0, "Amount > 0");
        require(blocksToStake > 0, "Blocks > 0");

        IERC20(token).transferFrom(msg.sender, address(this), amount);

        uint256 endBlock = block.number + blocksToStake;

        positions.push(Position({
            user: msg.sender,
            token: token,
            amount: amount,
            startBlock: block.number,
            endBlock: endBlock,
            claimed: false
        }));

        uint256 posId = positions.length - 1;
        activePositions[msg.sender].push(posId);
    }

    function releaseAll() public nonReentrant {
        uint256[] storage ids = activePositions[msg.sender];

        uint256 i = 0;
        while (i < ids.length) {
            uint256 posId = ids[i];
            Position storage p = positions[posId];

            if (!p.claimed && block.number >= p.endBlock) {
                p.claimed = true;

                uint256 refund = (p.amount * 995) / 1000;
                uint256 fee = p.amount - refund;

                IERC20(p.token).transfer(p.user, refund);
                IERC20(p.token).transfer(protocol, fee);

                // Move to history
                historyPositions[msg.sender].push(posId);

                // Remove from active array (swap & pop)
                ids[i] = ids[ids.length - 1];
                ids.pop();

            } else {
                i++;
            }
        }
    }

    function getXP(address holder, address token) external view returns (uint256 xp) {
        uint256[] memory act = activePositions[holder];
        uint256[] memory hist = historyPositions[holder];

        for (uint256 i = 0; i < act.length; i++) {
            Position memory p = positions[act[i]];
            if (p.token == token){
                uint256 effectiveEnd = p.endBlock > block.number ? block.number : p.endBlock;
                uint256 blocksStaked = effectiveEnd - p.startBlock;
                xp += blocksStaked * p.amount;
            }
        }
        for (uint256 j = 0; j < hist.length; j++) {
            Position memory p = positions[hist[j]];
            if (p.token == token){
                uint256 effectiveEnd = p.endBlock > block.number ? block.number : p.endBlock;
                uint256 blocksStaked = effectiveEnd - p.startBlock;
                xp += blocksStaked * p.amount;
            }
        }
    }

    function getPositionsPaginated(address user, uint256 offset, uint256 limit, bool active)
        external view returns (uint256[] memory page)
    {
        uint256[] storage source = active ? activePositions[user] : historyPositions[user];
        uint256 length = source.length;

        if (offset >= length) return new uint256[](0);

        uint256 end = offset + limit;
        if (end > length) end = length;

        page = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = source[i];
        }
    }
}
