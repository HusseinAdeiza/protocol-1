// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestCollection} from "./TestCollection.sol";

/// @notice Reports a successful transfer without moving the token. Hollow from
/// deployment; switch it off to list honestly and back on to fake a delivery.
contract HollowCollection is TestCollection {
    bool public hollow = true;

    constructor(address royaltyReceiver, uint96 bps) TestCollection("Hollow", "HOLE", royaltyReceiver, bps) {}

    function setHollow(bool value) external {
        hollow = value;
    }

    function transferFrom(address from, address to, uint256 tokenId) public override {
        if (hollow) return;
        super.transferFrom(from, to, tokenId);
    }
}
