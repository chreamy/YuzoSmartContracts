// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./YunaVault.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract YunaVaultRouter is Ownable(msg.sender) {
    bool public isRouterEnabled = true;
    address public factory;

    modifier onlyWhenRouterEnabled() {
        require(isRouterEnabled, "Router is disabled");
        _;
    }

    function stakeToVault(address vault, uint256 amount, uint256 blocksToStake) external onlyWhenRouterEnabled {
        IVault(vault).stake(amount, blocksToStake);
    }

    function releaseAllFromVault(address vault) external onlyWhenRouterEnabled {
        IVault(vault).releaseAll();
    }

    function releaseFromVault(address vault) external onlyWhenRouterEnabled {
        IVault(vault).release();
    }

    function getXPFromVault(address vault, address holder) external view returns (uint256) {
        return IVault(vault).getXP(holder);
    }

    function setFactory(address _factory) external onlyOwner {
        factory = _factory;
    }

    function disableRouter() external onlyOwner {
        isRouterEnabled = false;
    }

    function enableRouter() external onlyOwner {
        isRouterEnabled = true;
    }
}
