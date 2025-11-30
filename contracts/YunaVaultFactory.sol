// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./YunaVault.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract YunaVaultFactory {
    event VaultCreated(address indexed token, address vault);
    event VaultClosedByFactory(address indexed vault);

    address public protocol; 
    address public approvedRouter;
    address[] public allVaults;
    uint256 public protocolFeeBP = 50;
    uint256 public callerFeeBP = 25; 
    mapping(address => address) vaultForToken;
    
    constructor(address _protocol) {
        require(_protocol != address(0), "invalid protocol address");
        protocol = _protocol;
    }

    modifier onlyProtocol() {
        require(msg.sender == protocol || msg.sender == approvedRouter, "factory: only protocol");
        _;
    }
    

    struct TimeMultiplierIn { uint256 minBlocks; uint256 multiplierBP; }
    struct AmountMultiplierIn { uint256 minAmount; uint256 multiplierBP; }

    function setFees(uint256 _protocolFeeBP, uint256 _callerFeeBP) external onlyProtocol {
    require(_protocolFeeBP + _callerFeeBP < 10000, "fees too high");
        protocolFeeBP = _protocolFeeBP;
        callerFeeBP = _callerFeeBP;
    }

    function setApprovedRouter(address _router) external {
        require(msg.sender == protocol, "only protocol");
        approvedRouter = _router;
    }

    function createVault(
        address token,
        uint256 minDeposit,
        uint256 maxDeposit,
        int256 xpRate,
        uint256[] calldata presetTimes,
        TimeMultiplierIn[] calldata timeMultipliers,
        AmountMultiplierIn[] calldata amountMultipliers
    ) external onlyProtocol returns (address vaultAddr) {
        require(token != address(0), "token 0");
        require(vaultForToken[token] == address(0), "active vault exists");
        
        // Time multipliers
        YunaVault.TimeMultiplier[] memory _timeMul = new YunaVault.TimeMultiplier[](timeMultipliers.length);
        for (uint256 i = 0; i < timeMultipliers.length; i++) {
            if (i > 0) {
                require(
                    timeMultipliers[i].minBlocks > timeMultipliers[i - 1].minBlocks,
                    "Time multipliers not ascending"
                );
            }
            _timeMul[i] = YunaVault.TimeMultiplier({
                minBlocks: timeMultipliers[i].minBlocks,
                multiplierBP: timeMultipliers[i].multiplierBP
            });
        }

        // Amount multipliers
        YunaVault.AmountMultiplier[] memory _amountMul = new YunaVault.AmountMultiplier[](amountMultipliers.length);
        for (uint256 j = 0; j < amountMultipliers.length; j++) {
            if (j > 0) {
                require(
                    amountMultipliers[j].minAmount > amountMultipliers[j - 1].minAmount,
                    "Amount multipliers not ascending"
                );
            }
            _amountMul[j] = YunaVault.AmountMultiplier({
                minAmount: amountMultipliers[j].minAmount,
                multiplierBP: amountMultipliers[j].multiplierBP
            });
        }



        YunaVault vault = new YunaVault(
            protocol,
            token,
            address(this),
            minDeposit,
            maxDeposit,
            xpRate,
            presetTimes,
            _timeMul,
            _amountMul
        );

        vaultAddr = address(vault);
        allVaults.push(vaultAddr);
        vaultForToken[token] = vaultAddr;

        emit VaultCreated(token, vaultAddr);
    }

   function closeVault(address vaultAddr) external onlyProtocol {
    
        require(vaultAddr != address(0), "vault 0");

        YunaVault(vaultAddr).token();
        YunaVault(payable(vaultAddr)).closeVault();

        address token = YunaVault(vaultAddr).token();
        if (vaultForToken[token] == vaultAddr) {
            vaultForToken[token] = address(0);
        }

        emit VaultClosedByFactory(vaultAddr);
    }

    function getVaultByToken(address token) external view returns (address) {
        return vaultForToken[token];
    }

    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }

    function getVaultsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 length = allVaults.length;
        if (offset >= length) return page;
        uint256 end = offset + limit;
        if (end > length) end = length;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) page[i - offset] = allVaults[i];
    }
}