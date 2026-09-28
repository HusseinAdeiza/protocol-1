// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Backlit Panes, the genesis collection: 128 pieces, every one minted
/// at deployment, with a fixed royalty rate. The owner can point the metadata
/// at a new host and redirect the royalty until it freezes both; after that
/// nothing about the collection can change.
contract BacklitGenesis is ERC721, ERC2981 {
    using Strings for uint256;

    uint256 public constant SUPPLY = 128;
    uint96 public constant ROYALTY_BPS = 500;

    address public owner;
    address public pendingOwner;
    bool public frozen;
    string private baseUri;
    string private collectionUri;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Frozen();
    /// @dev ERC-4906, so marketplaces refresh after the metadata moves.
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);
    /// @dev ERC-7572, the same for the collection-level metadata.
    event ContractURIUpdated();

    error NotOwner();
    error NotPendingOwner();
    error IsFrozen();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier unfrozen() {
        if (frozen) revert IsFrozen();
        _;
    }

    constructor(
        address owner_,
        address holder,
        address royaltyReceiver,
        string memory baseUri_,
        string memory collectionUri_
    ) ERC721("Backlit Panes", "PANE") {
        if (owner_ == address(0) || holder == address(0) || royaltyReceiver == address(0)) revert ZeroAddress();
        owner = owner_;
        baseUri = baseUri_;
        collectionUri = collectionUri_;
        _setDefaultRoyalty(royaltyReceiver, ROYALTY_BPS);
        for (uint256 id = 1; id <= SUPPLY; id++) {
            _mint(holder, id);
        }
        emit OwnershipTransferred(address(0), owner_);
    }

    function totalSupply() external pure returns (uint256) {
        return SUPPLY;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string.concat(baseUri, tokenId.toString(), ".json");
    }

    /// @notice Collection-level metadata, as marketplaces read it.
    function contractURI() external view returns (string memory) {
        return collectionUri;
    }

    function setURIs(string calldata baseUri_, string calldata collectionUri_) external onlyOwner unfrozen {
        baseUri = baseUri_;
        collectionUri = collectionUri_;
        emit BatchMetadataUpdate(1, SUPPLY);
        emit ContractURIUpdated();
    }

    /// @notice The rate is fixed; only where it goes can change. A Backlit
    /// settlement is proved against the receiver's keys, so moving it while a
    /// listing is open voids any proof already built for that sale, and a
    /// receiver without keys stops Backlit sales until it registers them. Move
    /// it with no listings open.
    function setRoyaltyReceiver(address receiver) external onlyOwner unfrozen {
        if (receiver == address(0)) revert ZeroAddress();
        _setDefaultRoyalty(receiver, ROYALTY_BPS);
    }

    /// @notice Makes the metadata and the royalty receiver permanent.
    /// @dev Backlit pays the royalty into a note owned by the receiver's keys,
    /// so a market refuses to list or settle a Pane while the receiver has
    /// none registered with it (`BacklitMarket.hasKeys`). Keys are held per
    /// market and have to be registered again with a new one. Freezing with a
    /// receiver that can never register them, such as a contract with no way
    /// to call `registerKeys`, stops every Backlit sale of a Pane for good.
    function freeze() external onlyOwner unfrozen {
        frozen = true;
        emit Frozen();
    }

    /// @notice Nominates the next owner, who takes over by calling
    /// `acceptOwnership`, so the collection cannot pass to an address nobody
    /// controls. Nominating zero withdraws a nomination.
    function transferOwnership(address next) external onlyOwner {
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return interfaceId == 0x49064906 || super.supportsInterface(interfaceId);
    }
}
