// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {BacklitMarket} from "../src/BacklitMarket.sol";
import {BacklitPool} from "../src/BacklitPool.sol";
import {IVerifier} from "../src/interfaces/IVerifier.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {DeployGenesis} from "../script/DeployGenesis.s.sol";

import {MockSafe} from "./mocks/MockSafe.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";
import {TestnetWETH} from "./mocks/TestnetWETH.sol";

/// @notice Runs the genesis script's configuration under chain 4663, in order,
/// each step fixing the previous complaint and expecting the next, as
/// `Deploy.t.sol` does. The market is stood up at the address
/// deployments/4663.json records, so the test follows that file.
contract DeployGenesisGuardsTest is Test {
    using stdJson for string;

    DeployGenesis internal script;
    address internal deployer = makeAddr("deployer");
    address internal safe = makeAddr("safe");
    address internal holder = makeAddr("holder");
    address internal royalty = makeAddr("royalty");

    function setUp() public {
        script = new DeployGenesis();
    }

    /// Gives `account` the two getters a Safe answers, with one owner.
    function _makeSafe(address account) internal {
        vm.etch(account, address(new MockSafe()).code);
        address[] memory owners = new address[](1);
        owners[0] = makeAddr("safe owner");
        MockSafe(account).set(owners, 1);
    }

    function _expect(string memory reason) internal {
        vm.expectRevert(bytes(reason));
        script.loadConfig(deployer);
    }

    function test_mainnetRefusesACollectionThatCouldNotSell() public {
        vm.chainId(4663);
        vm.setEnv("GENESIS_OWNER", vm.toString(safe));
        vm.setEnv("GENESIS_HOLDER", vm.toString(holder));
        vm.setEnv("GENESIS_ROYALTY", vm.toString(royalty));
        vm.setEnv("GENESIS_SITE", "https://backlit.ink");

        _expect("mainnet: the owner must be a Safe the deployer does not own");

        _makeSafe(deployer);
        vm.setEnv("GENESIS_OWNER", vm.toString(deployer));
        _expect("mainnet: the deployer cannot own the collection");

        _makeSafe(safe);
        vm.setEnv("GENESIS_OWNER", vm.toString(safe));
        if (!vm.envExists("MARKET")) _expect("mainnet: MARKET must be set");

        // Right shape, wrong deployment: keys registered with another market
        // do not count on this one.
        vm.setEnv("MARKET", vm.toString(makeAddr("earlier market")));
        _expect("mainnet: MARKET is not the market in deployments/4663.json");

        address recorded = vm.readFile("deployments/4663.json").readAddress(".market");
        BacklitMarket market = _marketAt(recorded);
        vm.setEnv("MARKET", vm.toString(recorded));
        _expect("mainnet: the royalty receiver has no keys on MARKET");

        vm.prank(royalty);
        market.registerKeys(bytes32(uint256(1)), bytes32(uint256(2)));
        DeployGenesis.Config memory config = script.loadConfig(deployer);
        assertEq(config.owner, safe);
        assertEq(config.royalty, royalty);
        assertEq(config.market, recorded);

        // None of it applies off mainnet, where a keyless receiver and an
        // externally owned owner are fine.
        vm.chainId(46630);
        vm.setEnv("GENESIS_OWNER", vm.toString(makeAddr("eoa")));
        vm.setEnv("GENESIS_ROYALTY", vm.toString(makeAddr("keyless")));
        script.loadConfig(deployer);
    }

    function _marketAt(address where) internal returns (BacklitMarket) {
        BacklitPool pool = new BacklitPool(
            IWETH(address(new TestnetWETH())), IVerifier(address(new MockVerifier())), safe, 1 ether
        );
        deployCodeTo(
            "BacklitMarket.sol:BacklitMarket",
            abi.encode(address(pool), address(new MockVerifier()), safe, uint256(0), safe),
            where
        );
        return BacklitMarket(where);
    }
}
