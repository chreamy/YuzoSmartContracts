// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./YunaVaultFactory.sol";

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
    address public immutable factory;
    address public immutable vaultToken; 
    uint256 public immutable minDeposit;
    uint256 public immutable maxDeposit;
    int256 public immutable xpRate; 
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

    function _getRouter() internal view returns (address) {
        return YunaVaultFactory(factory).approvedRouter();
    }

    function getApprovedRouter() external view returns (address) {
        return _getRouter();
    }

    modifier onlyProtocol() {
        require(msg.sender == protocol || msg.sender == _getRouter() || msg.sender == factory, "only protocol");
        _;
    }

    constructor(
        address _protocol,
        address _token,
        address _factory,
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
        factory = _factory;

        presetTimes = _presetTimes;

        // copy multipliers arrays
        for (uint256 i = 0; i < _timeMultipliers.length; i++) {
            timeMultipliers.push(_timeMultipliers[i]);
        }
        for (uint256 i = 0; i < _amountMultipliers.length; i++) {
            amountMultipliers.push(_amountMultipliers[i]);
        }
    }

    function allowedPreset(uint256 blocks) public view returns (bool) {
        if (presetTimes.length == 0) return true; // if no preset restrictions, allow any
        for (uint256 i = 0; i < presetTimes.length; i++) {
            if (presetTimes[i] == blocks) return true;
        }
        return false;
    }

    function stakeFor(uint256 amount, uint256 blocksToStake, address beneficiary) external nonReentrant onlyProtocol {
        require(active && !closed, "vault not active");
        require(amount >= minDeposit && amount <= maxDeposit, "amount out of bounds");
        require(blocksToStake > 0, "blocks>0");
        require(allowedPreset(blocksToStake), "preset not allowed");

        IERC20(vaultToken).safeTransferFrom(msg.sender, address(this), amount);

        positions.push(Position({
            user: beneficiary,
            amount: amount,
            startBlock: block.number,
            endBlock: block.number + blocksToStake,
            claimed: false
        }));

        uint256 posId = positions.length - 1;
        activePositions[beneficiary].push(posId);

        if (!_seenParticipant[beneficiary]) {
            _seenParticipant[beneficiary] = true;
            _participants.push(beneficiary);
        }

        emit Staked(beneficiary, posId, amount, block.number, block.number + blocksToStake);
    }


    // release all matured positions, caller gets settlement fee (0.25%), protocol gets feeBP (0.5%)
    function releaseAll(address caller) external nonReentrant onlyProtocol {
        (uint256 feeBP, uint256 callerFeeBP) = getFees();
        uint256 totalBP = feeBP + callerFeeBP;
        
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
                if (callerFee > 0) IERC20(vaultToken).safeTransfer(caller, callerFee);
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


    function releaseFor(address user, address caller) external nonReentrant onlyProtocol {
        (uint256 feeBP, uint256 callerFeeBP) = getFees();
        uint256[] storage ids = activePositions[user];
        uint256 i = 0;

        while (i < ids.length) {
            uint256 posId = ids[i];
            Position storage p = positions[posId];

            bool matured = block.number >= p.endBlock;

            if (!p.claimed && (matured || closed)) {
                p.claimed = true;

                uint256 refund;
                uint256 fee;

                if (matured) {
                    uint256 totalFeeBP;

                    if (caller == user) {
                        totalFeeBP = feeBP; // protocol only
                    } else {
                        totalFeeBP = feeBP + callerFeeBP; // protocol + caller
                    }

                    fee = (p.amount * totalFeeBP) / 10000;
                    refund = p.amount - fee;

                    // protocol fee portion
                    uint256 protocolFee = (p.amount * feeBP) / 10000;

                    // caller fee portion (only when caller != user)
                    uint256 callerFee = 0;
                    if (caller != user) {
                        callerFee = fee - protocolFee;
                    }

                    if (protocolFee > 0) IERC20(vaultToken).safeTransfer(protocol, protocolFee);
                    if (callerFee > 0) IERC20(vaultToken).safeTransfer(caller, callerFee);
                    IERC20(vaultToken).safeTransfer(p.user, refund);

                    emit Released(p.user, posId, refund, fee);

                } else {
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


    function getFees() public view returns (uint256 _protocolFeeBP, uint256 _callerFeeBP) {
        YunaVaultFactory f = YunaVaultFactory(factory);
        return (f.protocolFeeBP(), f.callerFeeBP());
    }
    
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

    function getPositionsByAddress(address user) external view returns (Position[] memory) {
        uint256[] memory act = activePositions[user];
        uint256[] memory hist = historyPositions[user];
        Position[] memory result = new Position[](act.length + hist.length);

        for (uint256 i = 0; i < act.length; i++) {
            result[i] = positions[act[i]];
        }

        for (uint256 j = 0; j < hist.length; j++) {
            result[act.length + j] = positions[hist[j]];
        }

        return result;
    }

    function token() external view returns (address) {
        return vaultToken;
    }

    function isActive() external view returns (bool) {
        return active && !closed;
    }

    function closeVault() external onlyProtocol {
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
    
    function presetTimesLen() external view returns (uint256) {
    return presetTimes.length;
    }

    function positionsLength() external view returns (uint256) {
        return positions.length;
    }

    struct VaultAnalytics {
    uint256 totalStaked;
    uint256 activePositions;
    uint256 historyPositions;
    uint256 avgLockBlocks;
    uint256 avgAmount;
    uint256 totalPositions;
    uint256 totalXP;
    }

    function getVaultAnalytics()
    external
    view
    returns (VaultAnalytics memory info)
{
    uint256 totalLock = 0;
    uint256 totalAmount = 0;
    uint256 totalPos = 0;

    address[] memory users = _participants;

    for (uint256 i = 0; i < users.length; i++) {
        address user = users[i];

        // XP
        try this.getXP(user) returns (uint256 xp_) {
            info.totalXP += xp_;
        } catch {}

        // active + historical position IDs
        uint256[] storage act = activePositions[user];
        uint256[] storage hist = historyPositions[user];

        info.activePositions += act.length;
        info.historyPositions += hist.length;

        // iterate active
        for (uint256 j = 0; j < act.length; j++) {
            Position storage p = positions[act[j]];
            totalAmount += p.amount;
            totalLock += (p.endBlock - p.startBlock);
            totalPos++;
        }

        // iterate history
        for (uint256 j = 0; j < hist.length; j++) {
            Position storage p = positions[hist[j]];
            totalAmount += p.amount;
            totalLock += (p.endBlock - p.startBlock);
            totalPos++;
        }
    }

    info.totalPositions = totalPos;

    if (totalPos > 0) {
        info.avgLockBlocks = totalLock / totalPos;
        info.avgAmount = totalAmount / totalPos;
    }

    info.totalStaked = totalAmount;
    }


}