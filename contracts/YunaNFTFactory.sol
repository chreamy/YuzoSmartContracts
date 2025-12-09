// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./YunaNFT.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract YunaNFTFactory {
    using Strings for uint256;

    event CollectionCreated(address indexed owner, address collection);
    event BatchMinted(address indexed collection, uint256 count);

    function createCollection(
        string memory name,
        string memory symbol
    ) external returns (address) {
        YunaNFT collection = new YunaNFT(msg.sender, name, symbol);
        emit CollectionCreated(msg.sender, address(collection));
        return address(collection);
    }

    // Batch mint NFTs by generating IPFS URLs like: baseURL/ID.png
    function batchMintWithIPFS(
        address collection,
        address recipient,
        string memory baseURL,
        uint256 startId,
        uint256 endId,
        string memory baseDescription
    ) external {
        require(endId >= startId, "Invalid range");

        YunaNFT nft = YunaNFT(collection);
        require(nft.owner() == msg.sender, "Not collection owner");

        string memory baseName = nft.name(); // collection name

        uint256 count = (endId - startId) + 1;

        for (uint256 i = startId; i <= endId; i++) {

            // Construct URL: baseURL/i.png
            string memory url = string(
                abi.encodePacked(
                    baseURL,
                    "/",
                    i.toString(),
                    ".png"
                )
            );

            // Construct name: <CollectionName> #<i>
            string memory tokenName = string(
                abi.encodePacked(
                    baseName,
                    " #",
                    i.toString()
                )
            );

            nft.mintWithIPFS(
                recipient,
                url,
                tokenName,
                baseDescription
            );
        }

        emit BatchMinted(collection, count);
    }
}
