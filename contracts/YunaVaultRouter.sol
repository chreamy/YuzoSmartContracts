// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

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

    function stake(uint256 amount, uint256 blocksToStake) external;
    function release() external;
    function releaseAll() external;
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
    ) external onlyWhenRouterEnabled returns (address vaultAddr) {
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

    function closeVault(address vaultAddr) external onlyWhenRouterEnabled {
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

    function stake(address vault, uint256 amount, uint256 blocksToStake) external onlyWhenRouterEnabled {
        IVaultExtended(vault).stake(amount, blocksToStake);
    }

    function release(address vault) external onlyWhenRouterEnabled {
        IVaultExtended(vault).release();
    }

    function releaseAll(address vault) external onlyWhenRouterEnabled {
        IVaultExtended(vault).releaseAll();
    }

    function getXP(address vault, address holder) external view returns (uint256) {
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
        IVaultExtended v = IVaultExtended(vault);
        info.isActive = v.isActive();
        info.token = v.token();
        info.xpRate = v.xpRate();

        // Preset times
        uint256 len = v.presetTimesLen();
        info.presetTimes = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            info.presetTimes[i] = v.presetTimes(i);
        }

        // Time multipliers
        uint256 lenTime = v.timeMultipliersLen();
        info.timeMultipliers = new IVaultFactory.TimeMultiplierIn[](lenTime);
        for (uint256 i = 0; i < lenTime; i++) {
            (uint256 minBlocks, uint256 multiplierBP) = v.timeMultipliers(i);
            info.timeMultipliers[i] = IVaultFactory.TimeMultiplierIn({
                minBlocks: minBlocks,
                multiplierBP: multiplierBP
            });
        }

        // Amount multipliers
        uint256 lenAmount = v.amountMultipliersLen();
        info.amountMultipliers = new IVaultFactory.AmountMultiplierIn[](lenAmount);
        for (uint256 i = 0; i < lenAmount; i++) {
            (uint256 minAmount, uint256 multiplierBP) = v.amountMultipliers(i);
            info.amountMultipliers[i] = IVaultFactory.AmountMultiplierIn({
                minAmount: minAmount,
                multiplierBP: multiplierBP
            });
        }

        info.minDeposit = v.minDeposit();
        info.maxDeposit = v.maxDeposit();
    }
}
