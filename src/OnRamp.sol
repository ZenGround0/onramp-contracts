// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface OnRamp {
    struct Deal {
        bytes32 commP;
        int64 storage_duration;
        string location;
        uint256 amount;
        IERC20 token;
    }

    event DataReady(Deal deal, uint64 id);

    function offer_data(Deal calldata deal) external payable returns (DealID);
    function verify_data_stored(uint64 id) external returns (bool);
    function prove_data_stored(uint64 id, bytes calldata proof) external;
}

contract OnRampContract is OnRamp {
    uint64 private nextDealId = 1;
    uint64 private nextAggregateID = 1;
    mapping(uint64 => Deal) public deals;
    mapping(uint64 => uint64[]) public aggregations;

    function offer_data(Deal calldata deal) external payable override returns (uint64) {
        require(deal.token.transferFrom(msg.sender, address(this), deal.amount), "Payment transfer failed");

        uint64 id = nextDealId++;
        deals[id] = deal;

        emit DataReady(deal, id);
        return id;
    }

    function commit_aggregate(commP aggregate, uint64[] deals, PODSI[] deal_proofs, address payout_addr) external override {
        // check that the proofs are valid for each deal

        // create the aggregate

        // call into axelar bridge targeting our filecoin prover contracts
        // passing in aggregateID and commP 
    }

    function verify_data_stored(uint64 aggID, uint64 dealID) external override returns (bool) {

        // check agg proven

        // check agg refers to deal id

        return true;
    }

    // probably needs to be wrapped in an axelar _execute function
    function prove_data_stored(uint64 aggID, bytes calldata proof) external override {
        // check that the caller is one of our trusted filecoin data prover contracts 

        // transfer payment to the receiver 

        // mark agg proven 
    }
}