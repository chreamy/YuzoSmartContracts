// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IVault {
    function stake(uint256 amount, uint256 blocksToStake) external;
    function release() external;
    function releaseAll() external;
    function getXP(address holder) external view returns (uint256 xp);
    function token() external view returns (address);
    function isActive() external view returns (bool);
    function closeVault() external;
    function positionsLength() external view returns (uint256);
    function timeMultipliersLen() external view returns (uint256);
    function amountMultipliersLen() external view returns (uint256);
}

contract YunaVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Position {
        address user;
        uint256 amount;
        uint256 startBlock;
        uint256 endBlock;
        bool claimed;
    }

    struct TimeMultiplier {
        uint256 minBlocks;
        uint256 multiplierBP;
    }

    struct AmountMultiplier { // if amount >= minAmount then use multiplierBP
        uint256 minAmount;
        uint256 multiplierBP; // basis points
    }

    // immutable config
    address public immutable protocol; 
    address public immutable vaultToken; 
    uint256 public immutable minDeposit;
    uint256 public immutable maxDeposit;
    int256 public immutable xpRate; 
    uint256 public immutable feeBP = 500;
    uint256[] public presetTimes; // allowed lock lengths (in blocks)

    TimeMultiplier[] public timeMultipliers; // ordered by minBlocks asc
    AmountMultiplier[] public amountMultipliers; // ordered by minAmount asc

    bool public active = true; // once false, no new stakes allowed (closed by protocol)
    bool public closed = false; // closed for emergency refunds

    // Position storage
    Position[] public positions;
    mapping(address => uint256[]) public activePositions;
    mapping(address => uint256[]) public historyPositions;

    // track users who ever staked (optional helper for off-chain indexers)
    address[] internal _participants;
    mapping(address => bool) internal _seenParticipant;

    // events
    event Staked(address indexed user, uint256 indexed posId, uint256 amount, uint256 startBlock, uint256 endBlock);
    event Released(address indexed user, uint256 indexed posId, uint256 refund, uint256 fee);
    event EmergencyReleased(address indexed user, uint256 indexed posId, uint256 refund);
    event VaultClosed();

    modifier onlyProtocol() {
        require(msg.sender == protocol, "only protocol");
        _;
    }

    constructor(
        address _protocol,
        address _token,
        uint256 _minDeposit,
        uint256 _maxDeposit,
        int256 _xpRate,
        uint256[] memory _presetTimes,
        TimeMultiplier[] memory _timeMultipliers,
        AmountMultiplier[] memory _amountMultipliers
    ) {
        require(_protocol != address(0), "protocol 0");
        require(_token != address(0), "token 0");
        require(_minDeposit <= _maxDeposit, "min>max");

        protocol = _protocol;
        vaultToken = _token;
        minDeposit = _minDeposit;
        maxDeposit = _maxDeposit;
        xpRate = _xpRate;

        presetTimes = _presetTimes;

        // copy multipliers arrays
        for (uint256 i = 0; i < _timeMultipliers.length; i++) {
            timeMultipliers.push(_timeMultipliers[i]);
        }
        for (uint256 i = 0; i < _amountMultipliers.length; i++) {
            amountMultipliers.push(_amountMultipliers[i]);
        }
    }

    // --- staking ---

    function allowedPreset(uint256 blocks) public view returns (bool) {
        if (presetTimes.length == 0) return true; // if no preset restrictions, allow any
        for (uint256 i = 0; i < presetTimes.length; i++) {
            if (presetTimes[i] == blocks) return true;
        }
        return false;
    }

    function stake(uint256 amount, uint256 blocksToStake) external nonReentrant {
        require(active && !closed, "vault not active");
        require(amount >= minDeposit && amount <= maxDeposit, "amount out of bounds");
        require(blocksToStake > 0, "blocks>0");
        require(allowedPreset(blocksToStake), "preset not allowed");

        IERC20(vaultToken).safeTransferFrom(msg.sender, address(this), amount);

        positions.push(Position({
            user: msg.sender,
            amount: amount,
            startBlock: block.number,
            endBlock: block.number + blocksToStake,
            claimed: false
        }));

        uint256 posId = positions.length - 1;
        activePositions[msg.sender].push(posId);

        if (!_seenParticipant[msg.sender]) {
            _seenParticipant[msg.sender] = true;
            _participants.push(msg.sender);
        }

        emit Staked(msg.sender, posId, amount, block.number, block.number + blocksToStake);
    }

    // release all matured positions for caller (normal flow) - fee applies
    function release() external nonReentrant {
        _releaseFor(msg.sender, true);
    }

    // release all matured positions, caller gets settlement fee (0.25%), protocol gets feeBP (0.5%)
    function releaseAll() external nonReentrant {
        require(active && !closed, "vault not active");

        uint256 callerFeeBP = 25; // 0.25%
        uint256 totalBP = feeBP + callerFeeBP; // 0.5% + 0.25% = 0.75%
        
        for (uint256 posId = 0; posId < positions.length; posId++) {
            Position storage pos = positions[posId];
            if (!pos.claimed && block.number >= pos.endBlock) {
                pos.claimed = true;

                uint256 fee = (pos.amount * totalBP) / 10000;
                uint256 refund = pos.amount - fee;

                // split fee
                uint256 protocolFee = (pos.amount * feeBP) / 10000;
                uint256 callerFee = fee - protocolFee;

                if (protocolFee > 0) IERC20(vaultToken).safeTransfer(protocol, protocolFee);
                if (callerFee > 0) IERC20(vaultToken).safeTransfer(msg.sender, callerFee);
                IERC20(vaultToken).safeTransfer(pos.user, refund);

                emit Released(pos.user, posId, refund, fee);

                // move to historyPositions mapping
                historyPositions[pos.user].push(posId);

                // remove from activePositions mapping
                uint256[] storage userActive = activePositions[pos.user];
                for (uint256 i = 0; i < userActive.length; i++) {
                    if (userActive[i] == posId) {
                        userActive[i] = userActive[userActive.length - 1];
                        userActive.pop();
                        break;
                    }
                }
            }
        }
    }


    function _releaseFor(address user, bool takeFee) internal {
        uint256[] storage ids = activePositions[user];
        uint256 i = 0;
        while (i < ids.length) {
            uint256 posId = ids[i];
            Position storage p = positions[posId];

            // matured OR (emergency case where closed==true && we allow immediate refund)
            bool matured = block.number >= p.endBlock;
            if (!p.claimed && (matured || (closed && !takeFee))) {
                p.claimed = true;

                uint256 refund;
                uint256 fee;

                if (takeFee && matured) {
                    refund = (p.amount * (10000 - feeBP)) / 10000;
                    fee = p.amount - refund;
                    if (fee > 0) {
                        IERC20(vaultToken).safeTransfer(protocol, fee);
                    }
                    IERC20(vaultToken).safeTransfer(p.user, refund);
                    emit Released(p.user, posId, refund, fee);
                } else {
                    // emergency refund full principal
                    refund = p.amount;
                    IERC20(vaultToken).safeTransfer(p.user, refund);
                    emit EmergencyReleased(p.user, posId, refund);
                }

                // move to history
                historyPositions[user].push(posId);

                // remove from activePositions array (swap & pop)
                ids[i] = ids[ids.length - 1];
                ids.pop();
            } else {
                i++;
            }
        }
    }

    // helper: compute XP for holder across active+history for this vault's token only
    function getXP(address holder) external view returns (uint256 xp) {
        uint256[] memory act = activePositions[holder];
        uint256[] memory hist = historyPositions[holder];

        for (uint256 i = 0; i < act.length; i++) {
            Position memory p = positions[act[i]];
            uint256 effectiveEnd = p.endBlock > block.number ? block.number : p.endBlock;
            if (effectiveEnd <= p.startBlock) continue;
            uint256 blocks = effectiveEnd - p.startBlock;
            uint256 period = p.endBlock - p.startBlock;
            xp += _calcPositionXP(p.amount, blocks, period);
        }
        for (uint256 j = 0; j < hist.length; j++) {
            Position memory p = positions[hist[j]];
            if (p.endBlock <= p.startBlock) continue;
            uint256 blocks = p.endBlock - p.startBlock;
            xp += _calcPositionXP(p.amount, blocks, blocks);
        }
    }

    // compute base xp then apply multipliers (BP)
    function _calcPositionXP(uint256 amount, uint256 blocks, uint256 period) internal view returns (uint256) {
        uint256 base;

        if (xpRate >= 0) {
            // normal positive XP rate
            base = amount * blocks * uint256(xpRate);
        } else {
            // negative xpRate: reward 1 XP per x tokens per block
            uint256 absRate = uint256(-int256(xpRate));
            base = (amount * blocks) / absRate;
        }

        // apply multipliers
        uint256 timeMultBP = 10000;
        for (uint256 i = 0; i < timeMultipliers.length; i++) {
            if (period >= timeMultipliers[i].minBlocks) {
                timeMultBP = timeMultipliers[i].multiplierBP;
            } else {
                break;
            }
        }

        uint256 amountMultBP = 10000;
        for (uint256 k = 0; k < amountMultipliers.length; k++) {
            if (amount >= amountMultipliers[k].minAmount) {
                amountMultBP = amountMultipliers[k].multiplierBP;
            } else {
                break;
            }
        }

        uint256 combinedBP = (timeMultBP * amountMultBP) / 10000;
        uint256 finalXP = (base * combinedBP) / 10000;
        return finalXP;
    }


    function token() external view returns (address) {
        return vaultToken;
    }

    function isActive() external view returns (bool) {
        return active && !closed;
    }

    function closeVault() external {
        require(msg.sender == protocol, "only protocol");
        active = false;
        closed = true;
        emit VaultClosed();
    }

    function participants() external view returns (address[] memory) {
        return _participants;
    }

    function timeMultipliersLen() external view returns (uint256) {
        return timeMultipliers.length;
    }
    function amountMultipliersLen() external view returns (uint256) {
        return amountMultipliers.length;
    }

    function positionsLength() external view returns (uint256) {
        return positions.length;
    }

    function getPositionsPaginated(address user, uint256 offset, uint256 limit, bool _active)
        external view returns (uint256[] memory page)
    {
        uint256[] storage source = _active ? activePositions[user] : historyPositions[user];
        uint256 length = source.length;

        if (offset >= length) return page;

        uint256 end = offset + limit;
        if (end > length) end = length;

        page = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = source[i];
        }
    }
}