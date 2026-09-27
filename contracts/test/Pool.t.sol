// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BacklitPool} from "../src/BacklitPool.sol";
import {Field} from "../src/libs/Field.sol";
import {IVerifier} from "../src/interfaces/IVerifier.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";

import {BacklitTest} from "./Base.t.sol";
import {EchoVerifier} from "./mocks/EchoVerifier.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";

contract PoolTest is BacklitTest {
    event NoteCreated(uint256 indexed leafIndex, bytes32 commitment, bytes payload);
    event Withdrawn(address indexed to, uint256 amount);

    // ------------------------------------------------------------- deposits

    function test_depositETHCreatesTheRightCommitment() public {
        bytes32 salt = bytes32(uint256(7));
        bytes32 expected = commitmentOf(1 ether, BUYER_PK, salt);

        vm.expectEmit(true, false, false, true, address(pool));
        emit NoteCreated(0, expected, hex"01");

        depositAs(buyer, 1 ether, BUYER_PK, salt);

        assertEq(pool.leafCount(), 1);
        assertEq(pool.totalDeposited(), 1 ether);
        assertEq(weth.balanceOf(address(pool)), 1 ether);
        assertTrue(pool.isKnownRoot(pool.currentRoot()));
    }

    function test_depositWETHPullsAnApprovedBalance() public {
        vm.startPrank(buyer);
        weth.deposit{value: 2 ether}();
        weth.approve(address(pool), 2 ether);
        pool.depositWETH(2 ether, BUYER_PK, bytes32(uint256(9)), hex"01");
        vm.stopPrank();

        assertEq(weth.balanceOf(address(pool)), 2 ether);
        assertEq(pool.leafCount(), 1);
    }

    function test_depositRejectsZero() public {
        vm.prank(buyer);
        vm.expectRevert(BacklitPool.AmountOutOfRange.selector);
        pool.depositETH{value: 0}(BUYER_PK, bytes32(uint256(1)), hex"");
    }

    function test_depositRejectsAnAmountTheCircuitsCannotHold() public {
        uint256 tooBig = 2 ** 96;
        vm.deal(buyer, tooBig);
        vm.prank(buyer);
        vm.expectRevert(BacklitPool.AmountOutOfRange.selector);
        pool.depositETH{value: tooBig}(BUYER_PK, bytes32(uint256(1)), hex"");
    }

    function test_depositRejectsAKeyOutsideTheField() public {
        vm.prank(buyer);
        vm.expectRevert(Field.NotAFieldElement.selector);
        pool.depositETH{value: 1 ether}(bytes32(type(uint256).max), bytes32(uint256(1)), hex"");
    }

    function test_depositRespectsTheCap() public {
        BacklitPool small =
            new BacklitPool(IWETH(address(weth)), IVerifier(address(spendVerifier)), guardian, 1 ether);
        small.initMarket(address(market));

        vm.prank(buyer);
        small.depositETH{value: 1 ether}(BUYER_PK, bytes32(uint256(1)), hex"");

        vm.prank(buyer);
        vm.expectRevert(BacklitPool.CapExceeded.selector);
        small.depositETH{value: 1 wei}(BUYER_PK, bytes32(uint256(2)), hex"");
    }

    function test_depositsCanBePausedAndResumed() public {
        vm.prank(guardian);
        pool.setDepositsPaused(true);

        vm.prank(buyer);
        vm.expectRevert(BacklitPool.DepositsArePaused.selector);
        pool.depositETH{value: 1 ether}(BUYER_PK, bytes32(uint256(1)), hex"");

        vm.prank(guardian);
        pool.setDepositsPaused(false);
        depositAs(buyer, 1 ether, BUYER_PK, bytes32(uint256(1)));
        assertEq(pool.leafCount(), 1);
    }

    // ----------------------------------------------------------------- roots

    function test_theRootRingRemembersSixtyFourRoots() public {
        bytes32 first;
        for (uint256 i = 0; i < 64; i++) {
            depositAs(buyer, 0.01 ether, BUYER_PK, bytes32(i + 1));
            if (i == 0) first = pool.currentRoot();
        }
        assertTrue(pool.isKnownRoot(first), "the oldest root of the window is still known");
        assertEq(pool.knownRoots().length, 64);

        depositAs(buyer, 0.01 ether, BUYER_PK, bytes32(uint256(65)));
        assertFalse(pool.isKnownRoot(first), "the ring evicts the oldest root");
        assertTrue(pool.isKnownRoot(pool.currentRoot()));
    }

    function test_anUnknownRootIsRejected() public {
        assertFalse(pool.isKnownRoot(bytes32(uint256(12345))));
        assertFalse(pool.isKnownRoot(bytes32(0)));
    }

    // ---------------------------------------------------------------- spends

    function _spendPublic(uint256 withdrawAmount, address recipient, bool unwrap)
        internal
        view
        returns (BacklitPool.SpendPublic memory)
    {
        return BacklitPool.SpendPublic({
            root: pool.currentRoot(),
            nullifiers: [bytes32(uint256(1001)), bytes32(uint256(1002))],
            outputs: [bytes32(uint256(2001)), bytes32(uint256(2002))],
            withdrawAmount: withdrawAmount,
            recipient: recipient,
            unwrap: unwrap
        });
    }

    function test_spendWithdrawsAsETH() public {
        depositAs(buyer, 5 ether, BUYER_PK, bytes32(uint256(1)));
        address payable target = payable(makeAddr("target"));

        vm.expectEmit(true, false, false, true, address(pool));
        emit Withdrawn(target, 1 ether);

        pool.spend(hex"00", _spendPublic(1 ether, target, true), [bytes(hex"aa"), bytes(hex"bb")]);

        assertEq(target.balance, 1 ether);
        assertEq(weth.balanceOf(address(pool)), 4 ether);
        assertEq(pool.leafCount(), 3, "two outputs were inserted");
        assertTrue(pool.isSpent(bytes32(uint256(1001))));
        assertTrue(pool.isSpent(bytes32(uint256(1002))));
    }

    function test_spendWithdrawsAsWETH() public {
        depositAs(buyer, 5 ether, BUYER_PK, bytes32(uint256(1)));
        address target = makeAddr("target");

        pool.spend(hex"00", _spendPublic(2 ether, target, false), [bytes(hex"aa"), bytes(hex"bb")]);

        assertEq(weth.balanceOf(target), 2 ether);
        assertEq(target.balance, 0);
    }

    function test_spendWithNoWithdrawalMovesNothingOut() public {
        depositAs(buyer, 5 ether, BUYER_PK, bytes32(uint256(1)));
        pool.spend(hex"00", _spendPublic(0, address(0), false), [bytes(hex"aa"), bytes(hex"bb")]);
        assertEq(weth.balanceOf(address(pool)), 5 ether);
    }

    function test_spendRejectsABadProof() public {
        depositAs(buyer, 5 ether, BUYER_PK, bytes32(uint256(1)));
        // Build the arguments first: `expectRevert` claims the very next call,
        // and reading the root is a call.
        BacklitPool.SpendPublic memory p = _spendPublic(1 ether, buyer, true);
        spendVerifier.setAccepts(false);

        vm.expectRevert(BacklitPool.BadProof.selector);
        pool.spend(hex"00", p, [bytes(hex"aa"), bytes(hex"bb")]);
    }

    function test_spendRejectsAnUnknownRoot() public {
        depositAs(buyer, 5 ether, BUYER_PK, bytes32(uint256(1)));
        BacklitPool.SpendPublic memory p = _spendPublic(1 ether, buyer, true);
        p.root = bytes32(uint256(999));

        vm.expectRevert(BacklitPool.UnknownRoot.selector);
        pool.spend(hex"00", p, [bytes(hex"aa"), bytes(hex"bb")]);
    }

    function test_aNullifierIsNeverAcceptedTwice() public {
        depositAs(buyer, 5 ether, BUYER_PK, bytes32(uint256(1)));
        pool.spend(hex"00", _spendPublic(1 ether, buyer, true), [bytes(hex"aa"), bytes(hex"bb")]);

        BacklitPool.SpendPublic memory p = _spendPublic(1 ether, buyer, true);
        p.outputs = [bytes32(uint256(3001)), bytes32(uint256(3002))];

        vm.expectRevert(BacklitPool.NoteAlreadySpent.selector);
        pool.spend(hex"00", p, [bytes(hex"aa"), bytes(hex"bb")]);
    }

    function test_spendRejectsTheSameNoteTwiceInOneProof() public {
        depositAs(buyer, 5 ether, BUYER_PK, bytes32(uint256(1)));
        BacklitPool.SpendPublic memory p = _spendPublic(1 ether, buyer, true);
        p.nullifiers = [bytes32(uint256(1001)), bytes32(uint256(1001))];

        vm.expectRevert(BacklitPool.DuplicateNullifier.selector);
        pool.spend(hex"00", p, [bytes(hex"aa"), bytes(hex"bb")]);
    }

    function test_withdrawalsSurviveADepositPause() public {
        depositAs(buyer, 5 ether, BUYER_PK, bytes32(uint256(1)));

        vm.prank(guardian);
        pool.setDepositsPaused(true);

        address payable target = payable(makeAddr("target"));
        pool.spend(hex"00", _spendPublic(3 ether, target, true), [bytes(hex"aa"), bytes(hex"bb")]);
        assertEq(target.balance, 3 ether, "a pause must never reach a withdrawal");
    }

    function test_spendBuildsThePublicInputsTheCircuitExpects() public {
        BacklitPool echoed = new BacklitPool(
            IWETH(address(weth)), IVerifier(address(new EchoVerifier())), guardian, CAP
        );
        echoed.initMarket(address(market));

        vm.prank(buyer);
        echoed.depositETH{value: 1 ether}(BUYER_PK, bytes32(uint256(1)), hex"");

        BacklitPool.SpendPublic memory p = BacklitPool.SpendPublic({
            root: echoed.currentRoot(),
            nullifiers: [bytes32(uint256(1001)), bytes32(uint256(1002))],
            outputs: [bytes32(uint256(2001)), bytes32(uint256(2002))],
            withdrawAmount: 0.5 ether,
            recipient: buyer,
            unwrap: false
        });

        try echoed.spend(hex"00", p, [bytes(hex"aa"), bytes(hex"bb")]) {
            revert("the echo verifier always reverts");
        } catch (bytes memory reason) {
            bytes32[] memory publicInputs = abi.decode(_stripSelector(reason), (bytes32[]));

            assertEq(publicInputs.length, 9, "spend takes nine public inputs");
            assertEq(publicInputs[0], echoed.poolId());
            assertEq(publicInputs[1], bytes32(uint256(uint160(address(weth)))));
            assertEq(publicInputs[2], p.root);
            assertEq(publicInputs[3], p.nullifiers[0]);
            assertEq(publicInputs[4], p.nullifiers[1]);
            assertEq(publicInputs[5], p.outputs[0]);
            assertEq(publicInputs[6], p.outputs[1]);
            assertEq(publicInputs[7], bytes32(p.withdrawAmount));
            assertEq(publicInputs[8], bytes32(uint256(uint160(buyer))));
        }
    }

    // ----------------------------------------------------------- permissions

    function test_onlyTheMarketAppliesASettledSale() public {
        depositAs(buyer, 1 ether, BUYER_PK, bytes32(uint256(1)));
        bytes32 root = pool.currentRoot();

        vm.prank(stranger);
        vm.expectRevert(BacklitPool.NotTheMarket.selector);
        pool.spendFromMarket(
            root,
            [bytes32(uint256(1)), bytes32(uint256(2))],
            [bytes32(uint256(3)), bytes32(uint256(4)), bytes32(uint256(5))],
            [bytes(hex""), bytes(hex""), bytes(hex"")]
        );
    }

    function test_initMarketHappensOnceAndOnlyForTheDeployer() public {
        BacklitPool fresh =
            new BacklitPool(IWETH(address(weth)), IVerifier(address(spendVerifier)), guardian, CAP);

        vm.prank(stranger);
        vm.expectRevert(BacklitPool.NotTheDeployer.selector);
        fresh.initMarket(address(market));

        fresh.initMarket(address(market));
        vm.expectRevert(BacklitPool.AlreadyInitialised.selector);
        fresh.initMarket(address(0xdead));
    }

    function test_theCapOnlyGoesUp() public {
        vm.prank(guardian);
        pool.raiseCap(200 ether);
        assertEq(pool.capWei(), 200 ether);

        vm.prank(guardian);
        vm.expectRevert(BacklitPool.CapNotRaised.selector);
        pool.raiseCap(199 ether);

        vm.prank(stranger);
        vm.expectRevert(BacklitPool.NotTheGuardian.selector);
        pool.raiseCap(300 ether);
    }

    function test_theDeployerHoldsNoPrivilege() public {
        vm.expectRevert(BacklitPool.NotTheGuardian.selector);
        pool.raiseCap(200 ether);

        vm.expectRevert(BacklitPool.NotTheGuardian.selector);
        pool.setDepositsPaused(true);
    }

    function test_thePoolOnlyTakesETHFromWETH() public {
        vm.prank(stranger);
        (bool sent,) = address(pool).call{value: 1 ether}("");
        assertFalse(sent, "the pool is not a wallet");
    }

    function _stripSelector(bytes memory reason) private pure returns (bytes memory out) {
        out = new bytes(reason.length - 4);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = reason[i + 4];
        }
    }
}
