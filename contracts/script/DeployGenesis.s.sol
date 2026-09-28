// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {BacklitGenesis} from "../src/BacklitGenesis.sol";
import {BacklitMarket} from "../src/BacklitMarket.sol";
import {SafeCheck} from "./SafeCheck.sol";

/// Deploys Backlit Panes and records it in deployments/<chainId>-genesis.json.
///
///   GENESIS_OWNER        who may move the metadata and royalty until frozen (the guardian Safe)
///   GENESIS_HOLDER       who receives all 128 pieces
///   GENESIS_ROYALTY      who receives the 5% royalty; must register Backlit keys before sales settle
///   GENESIS_SITE         the site that serves /genesis, e.g. https://backlit.ink
///   MARKET               the BacklitMarket the pieces sell on; required on 4663
///
/// On 4663 the script refuses an owner that is not a Safe or is the deployer,
/// and it will not deploy a collection nobody can list yet: MARKET has to be
/// the market in deployments/4663.json and the royalty receiver has to have
/// registered keys with it, since `list` and `settle` refuse a Pane until then.
contract DeployGenesis is Script {
    using stdJson for string;

    uint256 internal constant MAINNET = 4663;

    struct Config {
        address owner;
        address holder;
        address royalty;
        string site;
        address market;
    }

    function run() external returns (BacklitGenesis genesis) {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        Config memory config = loadConfig(vm.addr(deployerKey));

        vm.startBroadcast(deployerKey);
        genesis = new BacklitGenesis(
            config.owner,
            config.holder,
            config.royalty,
            string.concat(config.site, "/genesis/metadata/"),
            string.concat(config.site, "/genesis/collection.json")
        );
        vm.stopBroadcast();

        require(genesis.balanceOf(config.holder) == 128, "the holder did not receive the supply");
        (address receiver,) = genesis.royaltyInfo(1, 10_000);
        require(receiver == config.royalty, "royalty receiver mismatch");

        string memory json = "genesis";
        vm.serializeAddress(json, "collection", address(genesis));
        vm.serializeAddress(json, "owner", config.owner);
        vm.serializeAddress(json, "holder", config.holder);
        vm.serializeAddress(json, "royaltyReceiver", config.royalty);
        string memory out = vm.serializeString(json, "site", config.site);
        vm.writeJson(out, string.concat("deployments/", vm.toString(block.chainid), "-genesis.json"));
        console.log("BacklitGenesis", address(genesis));
    }

    /// @dev Public so a test can run the mainnet guards without broadcasting.
    function loadConfig(address deployer) public view returns (Config memory config) {
        config.owner = vm.envAddress("GENESIS_OWNER");
        config.holder = vm.envAddress("GENESIS_HOLDER");
        config.royalty = vm.envAddress("GENESIS_ROYALTY");
        config.site = vm.envString("GENESIS_SITE");
        config.market = vm.envOr("MARKET", address(0));

        if (block.chainid == MAINNET) {
            require(SafeCheck.isSafe(config.owner, deployer), "mainnet: the owner must be a Safe the deployer does not own");
            require(config.owner != deployer, "mainnet: the deployer cannot own the collection");
            require(config.market != address(0), "mainnet: MARKET must be set");
            // Keys are registered per market, so a receiver registered with an
            // earlier deployment would pass a check against it and still block
            // sales here.
            require(
                config.market == vm.readFile("deployments/4663.json").readAddress(".market"),
                "mainnet: MARKET is not the market in deployments/4663.json"
            );
            require(
                BacklitMarket(config.market).hasKeys(config.royalty),
                "mainnet: the royalty receiver has no keys on MARKET"
            );
        }
    }
}
