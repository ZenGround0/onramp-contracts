// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { MarketAPI } from 'filecoin-solidity/contracts/v0.8/MarketAPI.sol';
import { CommonTypes } from 'filecoin-solidity/contracts/v0.8/types/CommonTypes.sol';
import { MarketTypes } from 'filecoin-solidity/contracts/v0.8/types/MarketTypes.sol';
import { AccountTypes } from 'filecoin-solidity/contracts/v0.8/types/AccountTypes.sol';
import { CommonTypes } from 'filecoin-solidity/contracts/v0.8/types/CommonTypes.sol';
import { AccountCBOR } from 'filecoin-solidity/contracts/v0.8/cbor/AccountCbor.sol';
import { MarketCBOR } from 'filecoin-solidity/contracts/v0.8/cbor/MarketCbor.sol';
import { BytesCBOR } from 'filecoin-solidity/contracts/v0.8/cbor/BytesCbor.sol';
import { BigNumbers, BigNumber } from 'solidity-bignumber/src/BigNumbers.sol';
import { BigInts } from 'filecoin-solidity/contracts/v0.8/utils/BigInts.sol';
import { CBOR } from 'solidity-cborutils/contracts/CBOR.sol';
import { Misc } from 'filecoin-solidity/contracts/v0.8/utils/Misc.sol';
import { FilAddresses } from 'filecoin-solidity/contracts/v0.8/utils/FilAddresses.sol';
import { IAxelarGateway } from '@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGateway.sol';
import { IAxelarGasService } from '@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol';
import { AxelarExecutable } from '@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol';

using CBOR for CBOR.CBORBuffer;

struct RequestId {
    bytes32 requestId;
    bool valid;
}

struct RequestIdx {
    uint256 idx;
    bool valid;
}

struct ProviderSet {
    bytes provider;
    bool valid;
}

// User request for this contract to make a deal. 
struct DealRequest {
    bytes piece_cid;
    int64 duration;
    uint64 id;
}

contract DealClient is AxelarExecutable {
    using AccountCBOR for *;
    using MarketCBOR for *;

    uint64 public constant AUTHENTICATE_MESSAGE_METHOD_NUM = 2643134072;
    uint64 public constant DATACAP_RECEIVER_HOOK_METHOD_NUM = 3726118371;
    uint64 public constant MARKET_NOTIFY_DEAL_METHOD_NUM = 4186741094;
    address public constant MARKET_ACTOR_ETH_ADDRESS = address(0xff00000000000000000000000000000000000005);
    address public constant DATACAP_ACTOR_ETH_ADDRESS = address(0xfF00000000000000000000000000000000000007);
    IAxelarGasService public immutable gasService;

    enum Status {
        None,
        RequestSubmitted,
        DealPublished,
        DealActivated,
        DealTerminated
    }

    DealRequest[] public dealRequests;


    mapping(bytes => uint64) public pieceDeals; // commP -> deal ID
    mapping(bytes => Status) public pieceStatus;

    event ReceivedDataCap(string received);

    address public owner;

    constructor(address gateway_, address gasReciever_) AxelarExecutable(gateway_) {
        gasService = IAxelarGasService(gasReciever_);
        owner = msg.sender;
    }

    function makeDealProposal(DealRequest memory deal) public returns (bytes32) {
        // require(msg.sender == owner);

        if (pieceStatus[deal.piece_cid] == Status.DealPublished || pieceStatus[deal.piece_cid] == Status.DealActivated) {
            revert('deal with this pieceCid already published');
        }

        uint256 index = dealRequests.length;
        dealRequests.push(deal);

        // creates a unique ID for the deal proposal -- there are many ways to do this
        bytes32 id = keccak256(abi.encodePacked(block.timestamp, msg.sender, index));
        dealRequestIdx[id] = RequestIdx(index, true);

        pieceRequests[deal.piece_cid] = RequestId(id, true);
        pieceStatus[deal.piece_cid] = Status.RequestSubmitted;

        return id;
    }

    function makeBatchDealProposal(DealRequest[] memory deals) public returns (bytes32[] memory) {
        // require(msg.sender == owner);

        bytes32[] memory ids = new bytes32[](deals.length);
        for (uint256 i = 0; i < deals.length; i++) {
            ids[i] = makeDealProposal(deals[i]);
        }
        return ids;
    }

    // Execute function to handle cross-chain deal request
    // Handles calls created by setAndSend. Updates this contract's value
    function _execute(string calldata sourceChain_, string calldata sourceAddress_, bytes calldata payload_) internal override {
        // DealRequest calldata deal;
        DealRequest[] memory deal = abi.decode(payload_, (DealRequest[]));
        makeBatchDealProposal(deal);
    }

    // helper function to get deal request based from id
    function getDealRequest(bytes32 requestId) internal view returns (DealRequest memory) {
        RequestIdx memory ri = dealRequestIdx[requestId];
        require(ri.valid, 'proposalId not available');
        return dealRequests[ri.idx];
    }



    function getExtraParams(bytes32 proposalId) public view returns (bytes memory extra_params) {
        DealRequest memory deal = getDealRequest(proposalId);
        return serializeExtraParamsV1(deal.extra_params);
    }

    // authenticateMessage is the callback from the market actor into the contract
    // as part of PublishStorageDeals. This message holds the deal proposal from the
    // miner, which needs to be validated by the contract in accordance with the
    // deal requests made and the contract's own policies
    // @params - cbor byte array of AccountTypes.AuthenticateMessageParams
    function authenticateMessage(bytes memory params) internal view {
        require(msg.sender == MARKET_ACTOR_ETH_ADDRESS, 'msg.sender needs to be market actor f05');

        AccountTypes.AuthenticateMessageParams memory amp = params.deserializeAuthenticateMessageParams();
        MarketTypes.DealProposal memory proposal = MarketCBOR.deserializeDealProposal(amp.message);

        bytes memory pieceCid = proposal.piece_cid.data;
        require(pieceRequests[pieceCid].valid, 'piece cid must be added before authorizing');
        require(!pieceProviders[pieceCid].valid, 'deal failed policy check: provider already claimed this cid');

        DealRequest memory req = getDealRequest(pieceRequests[pieceCid].requestId);
        require(proposal.verified_deal == req.verified_deal, 'verified_deal param mismatch');
        (uint256 proposalStoragePricePerEpoch, bool storagePriceConverted) = BigInts.toUint256(proposal.storage_price_per_epoch);
        require(!storagePriceConverted, 'Issues converting uint256 to BigInt, may not have accurate values');
        (uint256 proposalClientCollateral, bool collateralConverted) = BigInts.toUint256(proposal.client_collateral);
        require(!collateralConverted, 'Issues converting uint256 to BigInt, may not have accurate values');
        require(proposalStoragePricePerEpoch <= req.storage_price_per_epoch, 'storage price greater than request amount');
        require(proposalClientCollateral <= req.client_collateral, 'client collateral greater than request amount');
    }

    // dealNotify is the callback from the market actor into the contract at the end
    // of PublishStorageDeals. This message holds the previously approved deal proposal
    // and the associated dealID. The dealID is stored as part of the contract state
    // and the completion of this call marks the success of PublishStorageDeals
    // @params - cbor byte array of MarketDealNotifyParams
    function dealNotify(bytes memory params) internal {
        require(msg.sender == MARKET_ACTOR_ETH_ADDRESS, 'msg.sender needs to be market actor f05');

        MarketTypes.MarketDealNotifyParams memory mdnp = MarketCBOR.deserializeMarketDealNotifyParams(params);
        MarketTypes.DealProposal memory proposal = MarketCBOR.deserializeDealProposal(mdnp.dealProposal);

        // These checks prevent race conditions between the authenticateMessage and
        // marketDealNotify calls where someone could have 2 of the same deal proposals
        // within the same PSD msg, which would then get validated by authenticateMessage
        // However, only one of those deals should be allowed
        require(pieceRequests[proposal.piece_cid.data].valid, 'piece cid must be added before authorizing');
        require(!pieceProviders[proposal.piece_cid.data].valid, 'deal failed policy check: provider already claimed this cid');

        pieceProviders[proposal.piece_cid.data] = ProviderSet(proposal.provider.data, true);
        pieceDeals[proposal.piece_cid.data] = mdnp.dealId;
        pieceStatus[proposal.piece_cid.data] = Status.DealPublished;
    }


    function receiveDataCap(bytes memory params) internal {
        require(msg.sender == DATACAP_ACTOR_ETH_ADDRESS, 'msg.sender needs to be datacap actor f07');
        emit ReceivedDataCap('DataCap Received!');
        // Add get datacap balance api and store datacap amount
    }

    // handle_filecoin_method is the universal entry point for any evm based
    // actor for a call coming from a builtin filecoin actor
    // @method - FRC42 method number for the specific method hook
    // @params - CBOR encoded byte array params
    function handle_filecoin_method(uint64 method, uint64, bytes memory params) public returns (uint32, uint64, bytes memory) {
        bytes memory ret;
        uint64 codec;
        // dispatch methods
        if (method == AUTHENTICATE_MESSAGE_METHOD_NUM) {
            authenticateMessage(params);
            // If we haven't reverted, we should return a CBOR true to indicate that verification passed.
            CBOR.CBORBuffer memory buf = CBOR.create(1);
            buf.writeBool(true);
            ret = buf.data();
            codec = Misc.CBOR_CODEC;
        } else if (method == MARKET_NOTIFY_DEAL_METHOD_NUM) {
            dealNotify(params);
        } else if (method == DATACAP_RECEIVER_HOOK_METHOD_NUM) {
            receiveDataCap(params);
        } else {
            revert('the filecoin method that was called is not handled');
        }
        return (0, codec, ret);
    }
}