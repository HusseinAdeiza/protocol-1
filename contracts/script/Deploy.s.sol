// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {BacklitMarket} from "../src/BacklitMarket.sol";
import {BacklitPool} from "../src/BacklitPool.sol";
import {IVerifier} from "../src/interfaces/IVerifier.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {SettleVerifier} from "../src/verifiers/SettleVerifier.sol";
import {SpendVerifier} from "../src/verifiers/SpendVerifier.sol";
import {TestCollection} from "../test/mocks/TestCollection.sol";
import {TestnetWETH} from "../test/mocks/TestnetWETH.sol";

/// @notice Deploys Backlit and writes `deployments/<chainId>.json`.
///
///   forge script script/Deploy.s.sol --rpc-url <url> --broadcast
///
/// Environment:
///   DEPLOYER_KEY      the deploying account, read from a file or keychain
///   WETH_ADDRESS      an existing WETH; a TestnetWETH is deployed when unset
///   GUARDIAN          the Safe that may raise the cap and pause deposits
///   FEE_RECIPIENT     where the flat settlement fee goes
///   INITIAL_CAP       deposit cap in wei
///   FEE_WEI           flat fee per settled sale
///   FIXTURES          when true, also deploys a test collection
///   FIXTURE_BASE_URI  metadata base for that collection
contract Deploy is Script {
    using stdJson for string;

    struct Config {
        address deployer;
        address guardian;
        address feeRecipient;
        uint256 initialCap;
        uint256 feeWei;
        address weth;
        bool fixtures;
    }

    struct Deployed {
        address spendVerifier;
        address settleVerifier;
        address pool;
        address market;
        address collection;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        Config memory config = _config(vm.addr(deployerKey));

        vm.startBroadcast(deployerKey);
        Deployed memory out = _deploy(config);
        vm.stopBroadcast();

        _report(config, out);
    }

    function _config(address deployer) private view returns (Config memory config) {
        config.deployer = deployer;
        config.guardian = vm.envOr("GUARDIAN", deployer);
        config.feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        config.initialCap = vm.envOr("INITIAL_CAP", uint256(20 ether));
        config.feeWei = vm.envOr("FEE_WEI", uint256(0.0002 ether));
        config.weth = vm.envOr("WETH_ADDRESS", address(0));
        config.fixtures = vm.envOr("FIXTURES", false);
    }

    function _deploy(Config memory config) private returns (Deployed memory out) {
        if (config.weth == address(0)) {
            config.weth = address(new TestnetWETH());
        }

        out.spendVerifier = address(new SpendVerifier());
        out.settleVerifier = address(new SettleVerifier());

        BacklitPool pool = new BacklitPool(
            IWETH(config.weth), IVerifier(out.spendVerifier), config.guardian, config.initialCap
        );
        BacklitMarket market = new BacklitMarket(
            pool, IVerifier(out.settleVerifier), config.feeRecipient, config.feeWei, config.guardian
        );
        pool.initMarket(address(market));

        out.pool = address(pool);
        out.market = address(market);

        if (config.fixtures) {
            out.collection = _fixtures(config.deployer);
        }
    }

    function _fixtures(address deployer) private returns (address) {
        TestCollection sample = new TestCollection("Backlit Panes", "PANE", deployer, 500);
        string memory baseUri = vm.envOr("FIXTURE_BASE_URI", string(""));
        if (bytes(baseUri).length > 0) sample.setBaseURI(baseUri);
        for (uint256 i = 0; i < 12; i++) {
            sample.mint(deployer);
        }
        return address(sample);
    }

    function _report(Config memory config, Deployed memory out) private {
        console.log("WETH          ", config.weth);
        console.log("SpendVerifier ", out.spendVerifier);
        console.log("SettleVerifier", out.settleVerifier);
        console.log("BacklitPool   ", out.pool);
        console.log("BacklitMarket ", out.market);
        if (out.collection != address(0)) console.log("TestCollection", out.collection);

        string memory json = "deployment";
        json.serialize("chainId", block.chainid);
        json.serialize("weth", config.weth);
        json.serialize("spendVerifier", out.spendVerifier);
        json.serialize("settleVerifier", out.settleVerifier);
        json.serialize("pool", out.pool);
        json.serialize("market", out.market);
        json.serialize("guardian", config.guardian);
        json.serialize("feeRecipient", config.feeRecipient);
        json.serialize("feeWei", config.feeWei);
        json.serialize("capWei", config.initialCap);
        json.serialize("collection", out.collection);
        json.serialize("deployer", config.deployer);
        string memory finished = json.serialize("block", block.number);

        finished.write(string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
