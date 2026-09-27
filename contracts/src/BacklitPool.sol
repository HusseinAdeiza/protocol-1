// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LeanIMTData, InternalLeanIMT} from "@zk-kit/lean-imt.sol/InternalLeanIMT.sol";
import {PoseidonT5} from "poseidon-solidity/PoseidonT5.sol";

import {IVerifier} from "./interfaces/IVerifier.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {Field, MAX_NOTE_AMOUNT, SNARK_SCALAR_FIELD} from "./libs/Field.sol";

/// @title BacklitPool
/// @notice Holds WETH against private notes. A note is a commitment in the
/// pool's Merkle tree; spending one reveals a nullifier and nothing else.
///
/// The contract is immutable. The guardian can raise the deposit cap and stop
/// new deposits; it can never stop a withdrawal, move a note, or change a
/// verifier.
contract BacklitPool {
    using InternalLeanIMT for LeanIMTData;
    using Field for bytes32;

    IWETH public immutable weth;
    IVerifier public immutable spendVerifier;
    address public immutable guardian;
    address public immutable deployer;

    /// @notice Binds a proof to this deployment, so it cannot be replayed
    /// against another pool or another chain.
    bytes32 public immutable poolId;

    /// @notice Set once, by the deployer, to the market that settles sales.
    address public market;

    uint256 public capWei;
    bool public depositsPaused;

    /// @notice Cumulative deposits and withdrawals. The cap is measured on
    /// these rather than on `weth.balanceOf(pool)`, so WETH sent to the pool
    /// directly cannot use up the cap and block deposits.
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    LeanIMTData private tree;

    /// @dev Every root the tree has had. A proof built against an old root
    /// stays valid however busy the pool gets; its nullifiers are what stop
    /// a replay, not the age of the root.
    mapping(bytes32 root => bool) private rootSeen;

    mapping(bytes32 nullifier => bool) public isSpent;

    event NoteCreated(uint256 indexed leafIndex, bytes32 commitment, bytes payload);
    event Nullified(bytes32 indexed nullifier);
    event Deposited(address indexed from, uint256 amount, uint256 leafIndex);
    event Withdrawn(address indexed to, uint256 amount);
    event MarketSet(address indexed market);
    event CapRaised(uint256 capWei);
    event DepositsPaused(bool paused);

    error AlreadyInitialised();
    error BadProof();
    error CapExceeded();
    error DepositsArePaused();
    error DuplicateNullifier();
    error NoteAlreadySpent();
    error NotTheDeployer();
    error NotTheGuardian();
    error NotTheMarket();
    error AmountOutOfRange();
    error CapNotRaised();
    error UnknownRoot();
    error BadRecipient();
    error Reentered();
    error TransferFailed();
    error WithdrawalFailed();
    error ZeroAddress();

    struct SpendPublic {
        bytes32 root;
        bytes32[2] nullifiers;
        bytes32[2] outputs;
        uint256 withdrawAmount;
        address recipient;
        bool unwrap;
    }

    uint256 private locked = 1;

    modifier nonReentrant() {
        if (locked != 1) revert Reentered();
        locked = 2;
        _;
        locked = 1;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotTheGuardian();
        _;
    }

    constructor(IWETH weth_, IVerifier spendVerifier_, address guardian_, uint256 initialCapWei) {
        if (address(weth_) == address(0) || address(spendVerifier_) == address(0) || guardian_ == address(0))
        {
            revert ZeroAddress();
        }
        weth = weth_;
        spendVerifier = spendVerifier_;
        guardian = guardian_;
        deployer = msg.sender;
        capWei = initialCapWei;
        poolId = keccak256(abi.encode(block.chainid, address(this))).reduce();
        emit CapRaised(initialCapWei);
    }

    /// @notice Points the pool at its market. Callable once, by the deployer.
    function initMarket(address market_) external {
        if (msg.sender != deployer) revert NotTheDeployer();
        if (market != address(0)) revert AlreadyInitialised();
        if (market_ == address(0)) revert ZeroAddress();
        market = market_;
        emit MarketSet(market_);
    }

    // ---------------------------------------------------------------- deposits

    /// @notice Wraps ETH and turns it into a note owned by `ownerPk`.
    function depositETH(bytes32 ownerPk, bytes32 salt, bytes calldata payload) external payable {
        weth.deposit{value: msg.value}();
        _deposit(msg.value, ownerPk, salt, payload);
    }

    /// @notice Pulls WETH the caller has already approved and turns it into a note.
    function depositWETH(uint256 amount, bytes32 ownerPk, bytes32 salt, bytes calldata payload)
        external
    {
        if (!weth.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        _deposit(amount, ownerPk, salt, payload);
    }

    function _deposit(uint256 amount, bytes32 ownerPk, bytes32 salt, bytes calldata payload) private {
        if (depositsPaused) revert DepositsArePaused();
        if (amount == 0 || amount >= MAX_NOTE_AMOUNT) revert AmountOutOfRange();
        // Net value held against notes, after this deposit. Written without a
        // subtraction so it cannot underflow.
        if (totalDeposited + amount > capWei + totalWithdrawn) revert CapExceeded();

        bytes32 commitment = bytes32(
            PoseidonT5.hash(
                [uint256(uint160(address(weth))), amount, uint256(ownerPk.check()), uint256(salt.check())]
            )
        );

        totalDeposited += amount;
        uint256 leafIndex = _insert(commitment, payload);
        emit Deposited(msg.sender, amount, leafIndex);
    }

    // ------------------------------------------------------------------ spends

    /// @notice Spends two notes into two notes, optionally paying part of the
    /// value out to `recipient`. This is transfer, consolidation and withdrawal.
    function spend(bytes calldata proof, SpendPublic calldata p, bytes[2] calldata payloads)
        external
        nonReentrant
    {
        if (!isKnownRoot(p.root)) revert UnknownRoot();
        if (p.withdrawAmount >= MAX_NOTE_AMOUNT) revert AmountOutOfRange();
        // Paying to zero burns the value; paying to the pool strands it
        // outside every note.
        if (p.withdrawAmount > 0 && (p.recipient == address(0) || p.recipient == address(this))) {
            revert BadRecipient();
        }

        bytes32[] memory publicInputs = new bytes32[](9);
        publicInputs[0] = poolId;
        publicInputs[1] = Field.fromAddress(address(weth));
        publicInputs[2] = p.root;
        publicInputs[3] = p.nullifiers[0].check();
        publicInputs[4] = p.nullifiers[1].check();
        publicInputs[5] = p.outputs[0].check();
        publicInputs[6] = p.outputs[1].check();
        publicInputs[7] = bytes32(p.withdrawAmount);
        publicInputs[8] = spendBinding(p.recipient, p.unwrap, payloads);

        if (!spendVerifier.verify(proof, publicInputs)) revert BadProof();

        _nullify(p.nullifiers[0], p.nullifiers[1]);
        _insert(p.outputs[0], payloads[0]);
        _insert(p.outputs[1], payloads[1]);

        if (p.withdrawAmount > 0) {
            totalWithdrawn += p.withdrawAmount;
            if (p.unwrap) {
                weth.withdraw(p.withdrawAmount);
                (bool sent,) = p.recipient.call{value: p.withdrawAmount}("");
                if (!sent) revert WithdrawalFailed();
            } else {
                if (!weth.transfer(p.recipient, p.withdrawAmount)) revert TransferFailed();
            }
            emit Withdrawn(p.recipient, p.withdrawAmount);
        }
    }

    /// @notice Applies the note movement of a settled sale. The market has
    /// already verified the settle proof against these exact values.
    function spendFromMarket(
        bytes32 root,
        bytes32[2] calldata nullifiers,
        bytes32[3] calldata outputs,
        bytes[3] calldata payloads
    ) external {
        if (msg.sender != market) revert NotTheMarket();
        if (!isKnownRoot(root)) revert UnknownRoot();

        _nullify(nullifiers[0], nullifiers[1]);
        for (uint256 i = 0; i < 3; i++) {
            _insert(outputs[i], payloads[i]);
        }
    }

    // ------------------------------------------------------------------- views

    function currentRoot() external view returns (bytes32) {
        return bytes32(tree._root());
    }

    function leafCount() external view returns (uint256) {
        return tree.size;
    }

    function treeDepth() external view returns (uint256) {
        return tree.depth;
    }

    /// @notice True for any root the tree has ever had.
    function isKnownRoot(bytes32 root) public view returns (bool) {
        return rootSeen[root];
    }

    /// @notice What the spend circuit's `recipient` input is set to. The
    /// circuit only binds that slot, so hashing the payout terms and the
    /// payloads into it ties a proof to this exact call: nobody can replay it
    /// with the unwrap flag flipped or with payloads the owners cannot read.
    function spendBinding(address recipient, bool unwrap, bytes[2] calldata payloads)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(recipient, unwrap, keccak256(abi.encode(payloads)))).reduce();
    }

    // -------------------------------------------------------------- guardian

    /// @notice Raises the deposit cap. It can only go up.
    function raiseCap(uint256 newCapWei) external onlyGuardian {
        if (newCapWei <= capWei) revert CapNotRaised();
        capWei = newCapWei;
        emit CapRaised(newCapWei);
    }

    /// @notice Stops new deposits. Withdrawals and settlement are unaffected
    /// and there is no function that can stop them.
    function setDepositsPaused(bool paused) external onlyGuardian {
        depositsPaused = paused;
        emit DepositsPaused(paused);
    }

    // -------------------------------------------------------------- internals

    function _insert(bytes32 commitment, bytes calldata payload) private returns (uint256 leafIndex) {
        leafIndex = tree.size;
        rootSeen[bytes32(tree._insert(uint256(commitment.check())))] = true;
        emit NoteCreated(leafIndex, commitment, payload);
    }

    function _nullify(bytes32 a, bytes32 b) private {
        if (a == b) revert DuplicateNullifier();
        if (isSpent[a] || isSpent[b]) revert NoteAlreadySpent();
        isSpent[a] = true;
        isSpent[b] = true;
        emit Nullified(a);
        emit Nullified(b);
    }

    /// @dev Only the WETH contract pays ETH in, when a withdrawal unwraps.
    receive() external payable {
        if (msg.sender != address(weth)) revert TransferFailed();
    }
}
