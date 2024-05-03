// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {IERC20} from '../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {ProofData} from '../lib/raas-starter-kit/contracts/data-segment/ProofTypes.sol';
import {verify} from '../lib/raas-starter-kit/contracts/data-segment/Proof.sol';
import {cidToPieceCommitment} from '../lib/raas-starter-kit/contracts/data-segment/Cid.sol';


interface OnRamp {
    struct Deal {
        bytes commP;
        int64 duration;
        string location;
        uint256 amount;
        IERC20 token;
    }
    // struct Hint {string location, uint64 size} ? 
    // struct Payment {uint256 amount, IERC20 token}?


    event DataReady(Deal deal, uint64 id);

    function offerData(Deal calldata deal) external payable returns (DealID);
    function verifyDataStored(uint64 id) external returns (bool);
    function proveDataStored(uint64 id, bytes calldata proof) external;
}

contract OnRampContract is OnRamp {
    uint64 private nextDealId = 1;
    uint64 private nextAggregateID = 1;
    mapping(uint64 => Deal) public deals;
    mapping(uint64 => uint64[]) public aggregations;
    mapping(uint64 => address) public aggregationPayout;
    mapping(uint64 => bool) public provenAggregations;

    function offer_data(Deal calldata deal) external payable override returns (uint64) {
        require(deal.token.transferFrom(msg.sender, address(this), deal.amount), 'Payment transfer failed');

        uint64 id = nextDealId++;
        deals[id] = deal;

        emit DataReady(deal, id);
        return id;
    }

    // TODO: duration bounds checking 
    function commitAggregate(bytes aggregate, uint64[] claimedIDs, ProofData[] inclusionProofs, address payoutAddr) external override {
        uint64[] memory dealIDs = new uint64[](claimedIDs.length);
        // Prove all deals are committed by aggregate commP 
        for (uint64 i = 0; i < claimedIDs.length; i++) {
            uint64 dealID = claimedIDs[i];
            dealIDs[i] = dealID;
            require(verify(cidToPieceCommitment(deals[dealID].commP), aggregate, inclusionProofs[i]), 'Proof verification failed');

        }
        aggregations[nextAggregateID] = dealIDs;
        aggregationPayout[nextAggregateID] = payoutAddr;

        // call into axelar bridge targeting our filecoin prover contracts
        // passing in aggregateID and commP 
        // For tomorrow just call to the proving contract
    }

    function verifyDataStored(uint64 aggID, uint idx, uint64 dealID) external override returns (bool) {
        require(provenAggregations[aggID], 'Provided aggregation not proven');
        require(aggregations[aggID][idx] == dealID, 'Aggregation does not include deal');

        return true;
    }

    // probably needs to be wrapped in an axelar _execute function
    function proveDataStored(uint64 aggID) external override {
        // check that the caller is one of our trusted filecoin data prover contracts 
        // TODO methods to add trusted callers 

        // transfer payment to the receiver
        require(aggregationPayout[aggID].transfer(payment), 'Payment transfer failed');   

        // mark agg proven 
        provenAggregations[aggID] = true;
    }
}

