// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IVaultExtended {
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

    function stakeFor(uint256 amount, uint256 blocksToStake, address beneficiary) external;
    function releaseFor(address user, address caller) external;
    function releaseAll(address caller) external;
    function getXP(address holder) external view returns (uint256);
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

    // --- Factory/Admin Operations ---

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

    // --- Vault User Operations ---

    function stake(address tokenAddr, uint256 amount, uint256 blocksToStake) external onlyWhenRouterEnabled 
    {
        IERC20 token = IERC20(tokenAddr);
        token.safeTransferFrom(msg.sender, address(this), amount);
        address vaultAddr = IVaultFactory(factory).getVaultByToken(tokenAddr);
        require(vaultAddr != address(0), "vault not found");

        IVaultExtended vault = IVaultExtended(vaultAddr);
        token.approve(vaultAddr, amount);

        // Stake for the original user
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

    // --- Vault Info ---
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

    function getVaultInfo(address vault) external view returns (VaultInfo memory info) {
    // quick sanity: vault must be a contract
    require(vault != address(0), "vault 0");
    uint256 codeSize;
    assembly { codeSize := extcodesize(vault) }
    require(codeSize > 0, "not a contract");

    IVaultExtended v = IVaultExtended(vault);

    // Safe calls with try/catch to avoid bubbling reverts
    // isActive, token, xpRate are cheap and unlikely to revert, but wrap anyway.
    try v.isActive() returns (bool active_) { info.isActive = active_; } catch { info.isActive = false; }
    try v.token() returns (address token_) { info.token = token_; } catch { info.token = address(0); }
    try v.xpRate() returns (int256 xp_) { info.xpRate = xp_; } catch { info.xpRate = int256(0); }

    // presetTimes
    uint256 presetLen = 0;
    try v.presetTimesLen() returns (uint256 l) {
        presetLen = l;
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

    // timeMultipliers
    uint256 tLen = 0;
    try v.timeMultipliersLen() returns (uint256 tl) {
        tLen = tl;
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
        info.timeMultipliers = new IVaultFactory.TimeMultiplierIn[](0);
    }

    // amountMultipliers
    uint256 aLen = 0;
    try v.amountMultipliersLen() returns (uint256 al) {
        aLen = al;
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
        info.amountMultipliers = new IVaultFactory.AmountMultiplierIn[](0);
    }

    // min/max deposit
    try v.minDeposit() returns (uint256 md) { info.minDeposit = md; } catch { info.minDeposit = 0; }
    try v.maxDeposit() returns (uint256 Md) { info.maxDeposit = Md; } catch { info.maxDeposit = 0; }

    return info;
}

}
