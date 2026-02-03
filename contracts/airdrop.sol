// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Airdrop {

    event Airdropped(address indexed to, uint256 amount);

    function airdrop(
        address token,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external {
        require(recipients.length == amounts.length, "Length mismatch");

        IERC20 erc20 = IERC20(token);

        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }

        erc20.transferFrom(msg.sender, address(this), total);

        for (uint256 i = 0; i < recipients.length; i++) {
            erc20.transfer(recipients[i], amounts[i]);
            emit Airdropped(recipients[i], amounts[i]);
        }
    }
}
