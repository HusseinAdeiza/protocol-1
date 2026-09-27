// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice An ERC-721 with no royalty standard at all. Backlit must refuse it.
contract PlainCollection is ERC721 {
    uint256 public nextId;

    constructor() ERC721("Plain", "PLAIN") {}

    function mint(address to) external returns (uint256 tokenId) {
        tokenId = ++nextId;
        _mint(to, tokenId);
    }
}
