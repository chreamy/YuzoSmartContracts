// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Base64.sol";

contract YunaNFT is ERC721URIStorage, Ownable {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    // On-chain image storage (optional)
    mapping(uint256 => string) private _tokenImages;
    address public factory;

    constructor(
        address initialOwner,
        string memory name_,
        string memory symbol_
    ) ERC721(name_, symbol_) Ownable(initialOwner) {
        factory = msg.sender;
    }
    
    modifier onlyOwnerOrFactory() {
    require(msg.sender == owner() || msg.sender == factory, "Not authorized");
    _;
    }

    function mintWithIPFS(
        address recipient, 
        string memory imageURI,
        string memory name,
        string memory description
    ) public onlyOwnerOrFactory returns (uint256) {
        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();

        string memory metadata = string(
            abi.encodePacked(
                '{"name":"', name,
                '","description":"', description,
                '","image":"', imageURI,
                '"}'
            )
        );

        string memory encoded = Base64.encode(bytes(metadata));
        string memory tokenURI = string(
            abi.encodePacked("data:application/json;base64,", encoded)
        );

        _mint(recipient, newTokenId);
        _setTokenURI(newTokenId, tokenURI);

        return newTokenId;
    }

    function getTokenImage(uint256 tokenId) public view returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        return _tokenImages[tokenId];
    }

    function totalSupply() public view returns (uint256) {
        return _tokenIds.current();
    }
}
