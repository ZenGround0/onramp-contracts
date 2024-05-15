// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Cid} from "./Cid.sol";
import {TRUNCATOR} from "./Const.sol";
import {DataAttestation} from "./Oracles.sol";


// Adapted from https://github.com/lighthouse-web3/raas-starter-kit/blob/main/contracts/data-segment/Proof.sol
// adapted rather than imported to
//  1) avoid build issues
//  2) avoid npm deps 
//3)  avoid use of deprecated @zondax/filecoin-solidity
contract PODSIVerifier {

    // ProofData is a Merkle proof
    struct ProofData {
        uint64 index;
        bytes32[] path;
    }

    // verify verifies that the given leaf is present in the merkle tree with the given root.
    function verify(
        ProofData memory proof,
        bytes32 root,
        bytes32 leaf
    ) public pure returns (bool) {
        return computeRoot(proof, leaf) == root;
    }

    // computeRoot computes the root of a Merkle tree given a leaf and a Merkle proof.
    function computeRoot(ProofData memory d, bytes32 subtree) internal pure returns (bytes32) {
        require(d.path.length < 64, "merkleproofs with depths greater than 63 are not supported");
        require(d.index >> d.path.length == 0, "index greater than width of the tree");

        bytes32 carry = subtree;
        uint64 index = d.index;
        uint64 right = 0;

        for (uint64 i = 0; i < d.path.length; i++) {
            (right, index) = (index & 1, index >> 1);
            if (right == 1) {
                carry = computeNode(d.path[i], carry);
            } else {
                carry = computeNode(carry, d.path[i]);
            }
        }

        return carry;
    }

    // computeNode computes the parent node of two child nodes
    function computeNode(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        bytes32 digest = sha256(abi.encodePacked(left, right));
        return truncate(digest);
    }

    // truncate truncates a node to 254 bits.
    function truncate(bytes32 n) internal pure returns (bytes32) {
        // Set the two lowest-order bits of the last byte to 0
        return n & TRUNCATOR;
    }
}


contract OnRampContract is PODSIVerifier {
     struct Deal {
        bytes commP;
        int64 duration;
        string location;
        uint256 amount;
        IERC20 token;
    }
    // Possible rearrangement:
    // struct Hint {string location, uint64 size} ? 
    // struct Payment {uint256 amount, IERC20 token}?

    event DataReady(Deal deal, uint64 id);
    uint64 private nextDealId = 1;
    uint64 private nextAggregateID = 1;
    address public dataProofOracle;
    mapping(uint64 => Deal) public deals;
    mapping(uint64 => uint64[]) public aggregations;
    mapping(uint64 => address) public aggregationPayout;
    mapping(uint64 => bool) public provenAggregations;
    mapping(bytes => uint64) public commPToAggregateID;


    function setOracle(address oracle_) external {
        if (dataProofOracle == address(0)) {
            dataProofOracle = oracle_;
        } else {
            revert("Oracle already set");
        }
    }

    function offer_data(Deal calldata deal) external payable returns (uint64) {
        require(deal.token.transferFrom(msg.sender, address(this), deal.amount), "Payment transfer failed");

        uint64 id = nextDealId++;
        deals[id] = deal;

        emit DataReady(deal, id);
        return id;
    }

    function commitAggregate(bytes calldata aggregate, uint64[] calldata claimedIDs, ProofData[] calldata inclusionProofs, address payoutAddr) external {
        uint64[] memory dealIDs = new uint64[](claimedIDs.length);
        // Prove all deals are committed by aggregate commP 
        for (uint64 i = 0; i < claimedIDs.length; i++) {
            uint64 dealID = claimedIDs[i];
            dealIDs[i] = dealID;
            require(verify(inclusionProofs[i], Cid.cidToPieceCommitment(deals[dealID].commP), Cid.cidToPieceCommitment(aggregate)), "Proof verification failed");
        }
        aggregations[nextAggregateID] = dealIDs;
        aggregationPayout[nextAggregateID] = payoutAddr;
        commPToAggregateID[aggregate] = nextAggregateID;
    }

    function verifyDataStored(uint64 aggID, uint idx, uint64 dealID) external view returns (bool) {
        require(provenAggregations[aggID], "Provided aggregation not proven");
        require(aggregations[aggID][idx] == dealID, "Aggregation does not include deal");

        return true;
    }

    // Called by oracle to prove the data is stored
    function proveDataStored(uint64 aggID) external {
        require(msg.sender == dataProofOracle, "Only oracle can prove data stored");

        // transfer payment to the receiver
        for (uint i = 0; i < aggregations[aggID].length; i++) {
            uint64 dealID = aggregations[aggID][i];
            require(deals[dealID].token.transfer(aggregationPayout[aggID], deals[dealID].amount), "Payment transfer failed");
        }   
        provenAggregations[aggID] = true;
    }
}

