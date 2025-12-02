// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


interface IVaultExtended {
    struct Position {
        address user;
        uint256 amount;
        uint256 startBlock;
        uint256 endBlock;
        bool claimed;
    }
    function getPositionsByAddress(address user) external view returns (Position[] memory);
    function isActive() external view returns (bool);
    function token() external view returns (address);
    function xpRate() external view returns (int256);
    function presetTimesLen() external view returns (uint256);
    function presetTimes(uint256 index) external view returns (uint256);
    function timeMultipliersLen() external view returns (uint256);
    function timeMultipliers(uint256 index) external view returns (uint256 minBlocks, uint256 multiplierBP);
    function amountMultipliersLen() external view returns (uint256);
    function amountMultipliers(uint256 index) external view returns (uint256 minAmount, uint256 multiplierBP);
    function minDeposit() external view returns (uint256);
    function maxDeposit() external view returns (uint256);
    function getPositionsPaginated(address user, uint256 offset, uint256 limit, bool _active)
        external view returns (uint256[] memory page);
    function stakeFor(uint256 amount, uint256 blocksToStake, address beneficiary) external;
    function releaseFor(address user, address caller) external;
    function releaseAll(address caller) external;
    function getXP(address holder) external view returns (uint256);
    function participants() external view returns (address[] memory);
    function positions(uint256 index) external view returns (Position memory);
    function activePositions(address user) external view returns (uint256[] memory);
    function historyPositions(address user) external view returns (uint256[] memory);
    function getVaultAnalytics()
    external
    view
    returns (YunaVaultRouter.VaultAnalytics memory);
}

interface IVaultFactory {
    struct TimeMultiplierIn { uint256 minBlocks; uint256 multiplierBP; }
    struct AmountMultiplierIn { uint256 minAmount; uint256 multiplierBP; }

    function createVault(
        address token,
        uint256 minDeposit,
        uint256 maxDeposit,
        int256 xpRate,
        uint256[] calldata presetTimes,
        TimeMultiplierIn[] calldata timeMultipliers,
        AmountMultiplierIn[] calldata amountMultipliers
    ) external returns (address vaultAddr);

    function closeVault(address vaultAddr) external;

    function getAllVaults() external view returns (address[] memory);
    function getVaultByToken(address token) external view returns (address);

    function protocol() external view returns (address);

    function setFees(uint256 protocolFeeBP, uint256 callerFeeBP) external;
    function protocolFeeBP() external view returns (uint256);
    function callerFeeBP() external view returns (uint256);

}

contract YunaVaultRouter is Ownable {
    using SafeERC20 for IERC20;
    bool public isRouterEnabled = true;
    address public factory;

    modifier onlyWhenRouterEnabled() {
        require(isRouterEnabled, "Router is disabled");
        _;
    }

    constructor(address _factory, address _protocol) Ownable(msg.sender) {
        require(_factory != address(0), "factory 0");
        require(_protocol != address(0), "protocol 0");
        factory = _factory;

        _transferOwnership(_protocol);
    }

    function setFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "factory 0");
        factory = _factory;
    }

    function disableRouter() external onlyOwner {
        isRouterEnabled = false;
    }

    function enableRouter() external onlyOwner {
        isRouterEnabled = true;
    }

    function createVault(
        address token,
        uint256 minDeposit,
        uint256 maxDeposit,
        int256 xpRate,
        uint256[] calldata presetTimes,
        IVaultFactory.TimeMultiplierIn[] calldata timeMultipliers,
        IVaultFactory.AmountMultiplierIn[] calldata amountMultipliers
    ) external onlyWhenRouterEnabled onlyOwner returns (address vaultAddr) {
        vaultAddr = IVaultFactory(factory).createVault(
            token,
            minDeposit,
            maxDeposit,
            xpRate,
            presetTimes,
            timeMultipliers,
            amountMultipliers
        );
    }

    function closeVault(address vaultAddr) external onlyWhenRouterEnabled onlyOwner {
        IVaultFactory(factory).closeVault(vaultAddr);
    }

    function getAllVaults() external view returns (address[] memory) {
        return IVaultFactory(factory).getAllVaults();
    }

    function getVaultByToken(address token) external view returns (address) {
        return IVaultFactory(factory).getVaultByToken(token);
    }

    function setFees(uint256 protocolFeeBP, uint256 callerFeeBP) external onlyOwner {
        IVaultFactory(factory).setFees(protocolFeeBP, callerFeeBP);
    }

    function getFees() external view returns (uint256 protocolFeeBP, uint256 callerFeeBP) {
        return (IVaultFactory(factory).protocolFeeBP(), IVaultFactory(factory).callerFeeBP());
    }

    function getProtocol() external view returns (address) {
        return IVaultFactory(factory).protocol();
    }

    function getFactory() external view returns (address) {
        return factory;
    }

    function stake(address tokenAddr, uint256 amount, uint256 blocksToStake) external onlyWhenRouterEnabled 
    {
        IERC20 token = IERC20(tokenAddr);
        token.safeTransferFrom(msg.sender, address(this), amount);
        address vaultAddr = IVaultFactory(factory).getVaultByToken(tokenAddr);
        require(vaultAddr != address(0), "vault not found");

        IVaultExtended vault = IVaultExtended(vaultAddr);
        token.approve(vaultAddr, amount);
        vault.stakeFor(amount, blocksToStake, msg.sender);
    }


    function releaseFor(address vault, address beneficiary) external onlyWhenRouterEnabled {
        IVaultExtended(vault).releaseFor(beneficiary,msg.sender);
    }

    function releaseAll(address vault) external onlyWhenRouterEnabled {
        IVaultExtended(vault).releaseAll(msg.sender);
    }

    function getXP(address tokenAddr, address holder) external view returns (uint256) {
        address vaultAddr = IVaultFactory(factory).getVaultByToken(tokenAddr);
        require(vaultAddr != address(0), "vault not found");
        IVaultExtended vault = IVaultExtended(vaultAddr);
        return IVaultExtended(vault).getXP(holder);
    }

    struct TokenXP {
        address token;
        uint256 xp;
    }

    struct TokenPositions {
        address token;
        IVaultExtended.Position[] positions;
    }

    function getAllXP(address user)
        external
        view
        returns (TokenXP[] memory results)
    {
        address[] memory addresses = IVaultFactory(factory).getAllVaults();
        results = new TokenXP[](addresses.length);

        for (uint256 i; i < addresses.length; i++) {
            address token = IVaultExtended(addresses[i]).token();
            address vault = IVaultFactory(factory).getVaultByToken(token);

            uint256 xp = 0;
            if (vault != address(0)) {
                xp = IVaultExtended(vault).getXP(user);
            }

            results[i] = TokenXP({
                token: token,
                xp: xp
            });
        }
    }

    function getAllPositions(address user)
        external
        view
        returns (TokenPositions[] memory results)
    {
        address[] memory addresses = IVaultFactory(factory).getAllVaults();
        results = new TokenPositions[](addresses.length);

        for (uint256 i; i < addresses.length; i++) {
            IVaultExtended vault = IVaultExtended(addresses[i]);

            IVaultExtended.Position[] memory positions;
            positions = IVaultExtended(vault).getPositionsByAddress(user);
            

            results[i] = TokenPositions({
                token: IVaultExtended(vault).token(),
                positions: positions
            });
        }
    }
    struct VaultInfo {
        bool isActive;
        address token;
        int256 xpRate;
        uint256[] presetTimes;
        IVaultFactory.TimeMultiplierIn[] timeMultipliers;
        IVaultFactory.AmountMultiplierIn[] amountMultipliers;
        uint256 minDeposit;
        uint256 maxDeposit;
    }

    function getVaultInfo(address vault) 
    public 
    view 
    returns (VaultInfo memory info) 
{
    require(vault != address(0), "vault 0");
    uint256 codeSize;
    assembly { codeSize := extcodesize(vault) }
    require(codeSize > 0, "not a contract");

    IVaultExtended v = IVaultExtended(vault);
    try v.isActive() returns (bool active_) { info.isActive = active_; } catch { info.isActive = false; }
    try v.token() returns (address token_) { info.token = token_; } catch { info.token = address(0); }
    try v.xpRate() returns (int256 xp_) { info.xpRate = xp_; } catch { info.xpRate = int256(0); }

    try v.presetTimesLen() returns (uint256 presetLen) {
        info.presetTimes = new uint256[](presetLen);
        for (uint256 i = 0; i < presetLen; i++) {
            try v.presetTimes(i) returns (uint256 t) {
                info.presetTimes[i] = t;
            } catch {
                info.presetTimes[i] = 0;
            }
        }
    } catch {
        info.presetTimes = new uint256[](0);
    }

    try v.timeMultipliersLen() returns (uint256 tLen) {
        info.timeMultipliers = new IVaultFactory.TimeMultiplierIn[](tLen);
        for (uint256 i = 0; i < tLen; i++) {
            try v.timeMultipliers(i) returns (uint256 minBlocks, uint256 multiplierBP) {
                info.timeMultipliers[i] = IVaultFactory.TimeMultiplierIn({
                    minBlocks: minBlocks,
                    multiplierBP: multiplierBP
                });
            } catch {
                info.timeMultipliers[i] = IVaultFactory.TimeMultiplierIn({minBlocks: 0, multiplierBP: 10000});
            }
        }
    } catch {
        info.timeMultipliers = new IVaultFactory.TimeMultiplierIn[](0) ;
    }

    try v.amountMultipliersLen() returns (uint256 aLen) {
        info.amountMultipliers = new IVaultFactory.AmountMultiplierIn[](aLen);
        for (uint256 i = 0; i < aLen; i++) {
            try v.amountMultipliers(i) returns (uint256 minAmount, uint256 multiplierBP) {
                info.amountMultipliers[i] = IVaultFactory.AmountMultiplierIn({
                    minAmount: minAmount,
                    multiplierBP: multiplierBP
                });
            } catch {
                info.amountMultipliers[i] = IVaultFactory.AmountMultiplierIn({minAmount: 0, multiplierBP: 10000});
            }
        }
    } catch {
        info.amountMultipliers = new IVaultFactory.AmountMultiplierIn[](0) ;
    }

    try v.minDeposit() returns (uint256 md) { info.minDeposit = md; } catch { info.minDeposit = 0; }
    try v.maxDeposit() returns (uint256 Md) { info.maxDeposit = Md; } catch { info.maxDeposit = 0; }

    return info;
}


    struct UserXP {
    address user;
    uint256 xp;
    }

    function getVaultLeaderboardXP(address vault)
    external
    view
    returns (UserXP[] memory leaderboard)
{
    IVaultExtended v = IVaultExtended(vault);

    // get all users known to the factory for this vault
    address[] memory users = v.participants();

    leaderboard = new UserXP[](users.length);

    for (uint256 i; i < users.length; i++) {
        uint256 xp = 0;
        try v.getXP(users[i]) returns (uint256 xp_) {
            xp = xp_;
        } catch {}

        leaderboard[i] = UserXP({
            user: users[i],
            xp: xp
        });
    }

    // sort (descending xp)
    for (uint256 a = 0; a < leaderboard.length; a++) {
        for (uint256 b = a + 1; b < leaderboard.length; b++) {
            if (leaderboard[b].xp > leaderboard[a].xp) {
                UserXP memory temp = leaderboard[a];
                leaderboard[a] = leaderboard[b];
                leaderboard[b] = temp;
            }
        }
    }
}


    function getAllVaultInfo() external view returns (VaultInfo[] memory results) {
        address[] memory vaults = IVaultFactory(factory).getAllVaults();
        results = new VaultInfo[](vaults.length);

        for (uint256 i; i < vaults.length; i++) {
            results[i] = this.getVaultInfo(vaults[i]);
        }
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

    function getVaultAnalytics(address vault)
    external
    view
    returns (VaultAnalytics memory info)
{
    info = IVaultExtended(vault).getVaultAnalytics();
}


}
