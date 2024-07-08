// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { MarketAPI } from "lib/filecoin-solidity/contracts/v0.8/MarketAPI.sol";
import { CommonTypes } from "lib/filecoin-solidity/contracts/v0.8/types/CommonTypes.sol";
import { MarketTypes } from "lib/filecoin-solidity/contracts/v0.8/types/MarketTypes.sol";
import { AccountTypes } from "lib/filecoin-solidity/contracts/v0.8/types/AccountTypes.sol";
import { CommonTypes } from "lib/filecoin-solidity/contracts/v0.8/types/CommonTypes.sol";
import { AccountCBOR } from "lib/filecoin-solidity/contracts/v0.8/cbor/AccountCbor.sol";
import { MarketCBOR } from "lib/filecoin-solidity/contracts/v0.8/cbor/MarketCbor.sol";
import { BytesCBOR } from "lib/filecoin-solidity/contracts/v0.8/cbor/BytesCbor.sol";
import { BigInts } from "lib/filecoin-solidity/contracts/v0.8/utils/BigInts.sol";
import { CBOR } from "solidity-cborutils/contracts/CBOR.sol";
import { Misc } from "lib/filecoin-solidity/contracts/v0.8/utils/Misc.sol";
import { FilAddresses } from "lib/filecoin-solidity/contracts/v0.8/utils/FilAddresses.sol";
import { DataAttestation, IBridgeContract } from "./Oracles.sol";
import {Strings} from "lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import {AxelarExecutable} from "lib/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";
import { IAxelarGateway } from 'lib/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGateway.sol';
import { IAxelarGasService } from 'lib/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol';


using CBOR for CBOR.CBORBuffer;

contract DealClient is AxelarExecutable {
    using AccountCBOR for *;
    using MarketCBOR for *;

    IAxelarGasService public immutable gasService;
    uint64 public constant AUTHENTICATE_MESSAGE_METHOD_NUM = 2643134072;
    uint64 public constant DATACAP_RECEIVER_HOOK_METHOD_NUM = 3726118371;
    uint64 public constant MARKET_NOTIFY_DEAL_METHOD_NUM = 4186741094;
    address public constant MARKET_ACTOR_ETH_ADDRESS = address(0xff00000000000000000000000000000000000005);
    address public constant DATACAP_ACTOR_ETH_ADDRESS = address(0xfF00000000000000000000000000000000000007);
    uint256 public constant AXELAR_GAS_FEE = 100000000000000000; // Start with 1 FIL 

    enum Status {
        None,
        DealPublished,
        DealActivated,
        DealTerminated
    }

    mapping(bytes => uint64) public pieceDeals; // commP -> deal ID
    mapping(bytes => Status) public pieceStatus;
    mapping(int => uint256) public providerGasFunds; // Funds set aside for calling oracle by provider

    string destinationAddress;
    string destinationChain;

    constructor(address _gateway, address _gasReceiver) AxelarExecutable(_gateway) {
        gasService = IAxelarGasService(_gasReceiver);
    }

    function setOracle(string calldata _destinationAddress, string calldata _destinationChain) external {
        if (destinationAddress == "") {
            destinationAddress = _destinationAddress;
        } else {
            revert("Destination address already set");
        }
        if (destinationChain == "") {
            destinationChain = _destinationChain;
        } else {
            revert("Destination chain already set");
        }
    }

    function addGasFunds(uint64 providerID) external payable {
        providerGasFunds[providerID] += msg.value;
    }

    // dealNotify is the callback from the market actor into the contract at the end
    // of PublishStorageDeals. This message holds the previously approved deal proposal
    // and the associated dealID. The dealID is stored as part of the contract state
    // and the completion of this call marks the success of PublishStorageDeals
    // @params - cbor byte array of MarketDealNotifyParams
    function dealNotify(bytes memory params) internal {
        require(msg.sender == MARKET_ACTOR_ETH_ADDRESS, "msg.sender needs to be market actor f05");

        MarketTypes.MarketDealNotifyParams memory mdnp = MarketCBOR.deserializeMarketDealNotifyParams(params);
        MarketTypes.DealProposal memory proposal = MarketCBOR.deserializeDealProposal(mdnp.dealProposal);

        pieceDeals[proposal.piece_cid.data] = mdnp.dealId;
        pieceStatus[proposal.piece_cid.data] = Status.DealPublished;
        
        uint256 gasFunds = AXELAR_GAS_FEE;
        int64 duration = CommonTypes.ChainEpoch.unwrap(proposal.end_epoch) - CommonTypes.ChainEpoch.unwrap(proposal.start_epoch);
        DataAttestation memory attest = DataAttestation(proposal.piece_cid.data, duration, mdnp.dealId, uint256(Status.DealPublished));
        bytes memory payload = abi.encode(attest);

        if (providerGasFunds[proposal.provider] >= AXELAR_GAS_FEE) {
            providerGasFunds[proposal.provider] -= AXELAR_GAS_FEE;
        } else {
            gasFunds = providerGasFunds[proposal.provider];
            providerGasFunds[proposal.provider] = 0;
        }
        gasService.payNativeGasForContractCall{value: gasFunds}(
            address(this),
            destinationChain,
            destinationAddress,
            payload,
            msg.sender
        );
        gateway.callContract(this.destinationChain, this.destinationAddress, payload);
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
            // If we haven't reverted, we should return a CBOR true to indicate that verification passed.
            // Always authenticate message
            CBOR.CBORBuffer memory buf = CBOR.create(1);
            buf.writeBool(true);
            ret = buf.data();
            codec = Misc.CBOR_CODEC;
        } else if (method == MARKET_NOTIFY_DEAL_METHOD_NUM) {
            dealNotify(params);
        } else {
            revert('the filecoin method that was called is not handled');
        }
        return (0, codec, ret);
    }
    function addressToHexString(address _addr) internal pure returns (string memory) {
        return Strings.toHexString(uint256(uint160(_addr)), 20);
    }
}

