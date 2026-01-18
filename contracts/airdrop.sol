// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Airdrop is Ownable(msg.sender) {
    event Airdropped(address indexed to, uint256 amount);

    function airdrop(
        address token,
        address from,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyOwner {
        require(recipients.length == amounts.length, "Length mismatch");

        IERC20 erc20 = IERC20(token);
        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }

        require(
            erc20.transferFrom(from, address(this), total),
            "TransferFrom failed"
        );

        for (uint256 i = 0; i < recipients.length; i++) {
            require(
                erc20.transfer(recipients[i], amounts[i]),
                "Transfer failed"
            );
            emit Airdropped(recipients[i], amounts[i]);
        }
    }
}
