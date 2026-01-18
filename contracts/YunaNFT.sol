// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

contract Airdrop {
    address public owner;

    event AirdropSent(address indexed to, uint256 amount);

    constructor() {
        owner = msg.sender;
    }

    function airdrop(
        address token,
        address[] calldata addresses,
        uint256[] calldata amounts
    ) external {
        require(addresses.length == amounts.length, "invalid array length");

        IERC20 erc20 = IERC20(token);

        for (uint256 i = 0; i < addresses.length; i++) {
            require(
                erc20.transfer(addresses[i], amounts[i]),
                "Failed to send tokens"
            );
            emit AirdropSent(addresses[i], amounts[i]);
        }
    }
}
