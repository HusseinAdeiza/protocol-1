// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice A minimal ERC-721 that answers ERC-2981, standing in for a real
/// collection in tests and on testnet.
contract TestCollection is ERC721, ERC2981 {
    using Strings for uint256;

    uint256 public nextId;
    string private baseUri;

    constructor(string memory name_, string memory symbol_, address royaltyReceiver, uint96 bps)
        ERC721(name_, symbol_)
    {
        _setDefaultRoyalty(royaltyReceiver, bps);
    }

    /// @notice Points the collection at hosted metadata, so a test deployment
    /// can look like the real thing.
    function setBaseURI(string calldata uri) external {
        baseUri = uri;
    }

    function mint(address to) external returns (uint256 tokenId) {
        tokenId = ++nextId;
        _mint(to, tokenId);
    }

    function setRoyalty(address receiver, uint96 bps) external {
        _setDefaultRoyalty(receiver, bps);
    }

    function setTokenRoyalty(uint256 tokenId, address receiver, uint96 bps) external {
        _setTokenRoyalty(tokenId, receiver, bps);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (bytes(baseUri).length == 0) return "data:application/json;base64,e30=";
        return string.concat(baseUri, tokenId.toString(), ".json");
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
