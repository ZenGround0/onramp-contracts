// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {MarketAPI} from "lib/filecoin-solidity/contracts/v0.8/MarketAPI.sol";
import {CommonTypes} from "lib/filecoin-solidity/contracts/v0.8/types/CommonTypes.sol";
import {MarketTypes} from "lib/filecoin-solidity/contracts/v0.8/types/MarketTypes.sol";
import {AccountTypes} from "lib/filecoin-solidity/contracts/v0.8/types/AccountTypes.sol";
import {CommonTypes} from "lib/filecoin-solidity/contracts/v0.8/types/CommonTypes.sol";
import {AccountCBOR} from "lib/filecoin-solidity/contracts/v0.8/cbor/AccountCbor.sol";
import {MarketCBOR} from "lib/filecoin-solidity/contracts/v0.8/cbor/MarketCbor.sol";
import {BytesCBOR} from "lib/filecoin-solidity/contracts/v0.8/cbor/BytesCbor.sol";
import {BigInts} from "lib/filecoin-solidity/contracts/v0.8/utils/BigInts.sol";
import {CBOR} from "solidity-cborutils/contracts/CBOR.sol";
import {Misc} from "lib/filecoin-solidity/contracts/v0.8/utils/Misc.sol";
import {FilAddresses} from "lib/filecoin-solidity/contracts/v0.8/utils/FilAddresses.sol";
import {DataAttestation, IBridgeContract, StringsEqual} from "./Oracles.sol";
import {Strings} from "lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import {AxelarExecutable} from "lib/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";
import {IAxelarGateway} from "lib/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGateway.sol";
import {IAxelarGasService} from "lib/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol";
import {BLAKE2b} from "./blake2lib.sol";

using CBOR for CBOR.CBORBuffer;

contract DealClient is AxelarExecutable {
    using AccountCBOR for *;
    using MarketCBOR for *;

    IAxelarGasService public immutable gasService;
    uint64 public constant AUTHENTICATE_MESSAGE_METHOD_NUM = 2643134072;
    uint64 public constant DATACAP_RECEIVER_HOOK_METHOD_NUM = 3726118371;
    uint64 public constant MARKET_NOTIFY_DEAL_METHOD_NUM = 4186741094;
    address public constant MARKET_ACTOR_ETH_ADDRESS =
        address(0xff00000000000000000000000000000000000005);
    address public constant DATACAP_ACTOR_ETH_ADDRESS =
        address(0xfF00000000000000000000000000000000000007);
    uint256 public constant AXELAR_GAS_FEE = 100000000000000000; // Start with 0.1 FIL

    struct DestinationChain {
        string chainName;
        address destinationAddress;
    }

    enum Status {
        None,
        DealPublished,
        DealActivated,
        DealTerminated
    }

    mapping(bytes => uint64) public pieceDeals; // commP -> deal ID
    mapping(bytes => Status) public pieceStatus;
    mapping(bytes => uint256) public providerGasFunds; // Funds set aside for calling oracle by provider
    mapping(uint256 => DestinationChain) public chainIdToDestinationChain;
    event DealNotify(
        uint64 dealId,
        bytes commP,
        bytes data,
        bytes chainId,
        bytes provider,
        bytes payload
    );
    event ReceivedDataCap(string received);

    constructor(
        address _gateway,
        address _gasReceiver
    ) AxelarExecutable(_gateway) {
        gasService = IAxelarGasService(_gasReceiver);
    }

    function setDestinationChains(
        uint[] calldata chainIds,
        string[] calldata destinationChains,
        address[] calldata destinationAddresses
    ) external {
        require(
            chainIds.length == destinationChains.length &&
                destinationChains.length == destinationAddresses.length,
            "Input arrays must have the same length"
        );

        for (uint i = 0; i < chainIds.length; i++) {
            require(
                chainIdToDestinationChain[chainIds[i]].destinationAddress ==
                    address(0),
                "Destination chains already configured for the chainId"
            );
            chainIdToDestinationChain[chainIds[i]] = DestinationChain(
                destinationChains[i],
                destinationAddresses[i]
            );
        }
    }

    function addGasFunds(bytes calldata providerAddrData) external payable {
        providerGasFunds[providerAddrData] += msg.value;
    }

    function receiveDataCap(bytes memory) internal {
        require(
            msg.sender == DATACAP_ACTOR_ETH_ADDRESS,
            "msg.sender needs to be datacap actor f07"
        );
        emit ReceivedDataCap("DataCap Received!");
        // Add get datacap balance api and store datacap amount
    }

    // authenticateMessage is the callback from the market actor into the contract
    // as part of PublishStorageDeals. This message holds the deal proposal from the
    // miner, which needs to be validated by the contract in accordance with the
    // deal requests made and the contract's own policies
    // @params - cbor byte array of AccountTypes.AuthenticateMessageParams
    function authenticateMessage(bytes memory params) internal view {
        require(
            msg.sender == MARKET_ACTOR_ETH_ADDRESS,
            "msg.sender needs to be market actor f05"
        );

        AccountTypes.AuthenticateMessageParams memory amp = params
            .deserializeAuthenticateMessageParams();
        MarketTypes.DealProposal memory proposal = MarketCBOR
            .deserializeDealProposal(amp.message);
        bytes memory encodedData = convertAsciiHexToBytes(proposal.label.data);
        (, address filAddress) = abi.decode(encodedData, (uint256, address));
        address recovered = recovers(
            bytes32(BLAKE2b.hash(amp.message, "", "", "", 32)),
            amp.signature
        );
        require(recovered == filAddress, "Invalid signature");
    }

    // dealNotify is the callback from the market actor into the contract at the end
    // of PublishStorageDeals. This message holds the previously approved deal proposal
    // and the associated dealID. The dealID is stored as part of the contract state
    // and the completion of this call marks the success of PublishStorageDeals
    // @params - cbor byte array of MarketDealNotifyParams
    function dealNotify(bytes memory params) internal {
        require(
            msg.sender == MARKET_ACTOR_ETH_ADDRESS,
            "msg.sender needs to be market actor f05"
        );

        MarketTypes.MarketDealNotifyParams memory mdnp = MarketCBOR
            .deserializeMarketDealNotifyParams(params);
        MarketTypes.DealProposal memory proposal = MarketCBOR
            .deserializeDealProposal(mdnp.dealProposal);

        pieceDeals[proposal.piece_cid.data] = mdnp.dealId;
        pieceStatus[proposal.piece_cid.data] = Status.DealPublished;

        int64 duration = CommonTypes.ChainEpoch.unwrap(proposal.end_epoch) -
            CommonTypes.ChainEpoch.unwrap(proposal.start_epoch);
        // Expects deal label to be chainId encoded in bytes
        // string memory chainIdStr = abi.decode(proposal.label.data, (string));
        bytes memory encodedData = convertAsciiHexToBytes(proposal.label.data);
        (uint256 chainId, ) = abi.decode(encodedData, (uint256, address));

        // uint256 chainId = asciiBytesToUint(proposal.label.data);
        DataAttestation memory attest = DataAttestation(
            proposal.piece_cid.data,
            duration,
            mdnp.dealId,
            uint256(Status.DealPublished)
        );
        bytes memory payload = abi.encode(attest);

        emit DealNotify(
            mdnp.dealId,
            proposal.piece_cid.data,
            params,
            proposal.label.data,
            proposal.provider.data,
            payload
        );
        if (chainId == block.chainid) {
            IBridgeContract(
                chainIdToDestinationChain[chainId].destinationAddress
            )._execute(
                    chainIdToDestinationChain[chainId].chainName,
                    addressToHexString(address(this)),
                    payload
                );
        } else {
            // If the chainId is not the current chain, we need to call the gateway
            // to forward the message to the correct chain
            call_axelar(
                payload,
                proposal.provider.data,
                AXELAR_GAS_FEE,
                chainId
            );
        }
    }

    function call_axelar(
        bytes memory payload,
        bytes memory providerAddrData,
        uint256 gasTarget,
        uint256 chainId
    ) internal {
        uint256 gasFunds = gasTarget;
        if (providerGasFunds[providerAddrData] >= gasTarget) {
            providerGasFunds[providerAddrData] -= gasTarget;
        } else {
            gasFunds = providerGasFunds[providerAddrData];
            providerGasFunds[providerAddrData] = 0;
        }
        string memory destinationChain = chainIdToDestinationChain[chainId]
            .chainName;
        string memory destinationAddress = addressToHexString(
            chainIdToDestinationChain[chainId].destinationAddress
        );
        gasService.payNativeGasForContractCall{value: gasFunds}(
            address(this),
            destinationChain,
            destinationAddress,
            payload,
            msg.sender
        );
        gateway.callContract(destinationChain, destinationAddress, payload);
    }

    function debug_call(
        bytes calldata commp,
        bytes calldata providerAddrData,
        uint256 gasFunds,
        uint256 chainId
    ) public {
        DataAttestation memory attest = DataAttestation(
            commp,
            0,
            42,
            uint256(Status.DealPublished)
        );
        bytes memory payload = abi.encode(attest);
        if (chainId == block.chainid) {
            IBridgeContract(
                chainIdToDestinationChain[chainId].destinationAddress
            )._execute(
                    chainIdToDestinationChain[chainId].chainName,
                    addressToHexString(address(this)),
                    payload
                );
        } else {
            // If the chainId is not the current chain, we need to call the gateway
            // to forward the message to the correct chain
            call_axelar(payload, providerAddrData, gasFunds, chainId);
        }
    }

    // handle_filecoin_method is the universal entry point for any evm based
    // actor for a call coming from a builtin filecoin actor
    // @method - FRC42 method number for the specific method hook
    // @params - CBOR encoded byte array params
    function handle_filecoin_method(
        uint64 method,
        uint64,
        bytes memory params
    ) public returns (uint32, uint64, bytes memory) {
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
            revert("the filecoin method that was called is not handled");
        }
        return (0, codec, ret);
    }

    function addressToHexString(
        address _addr
    ) internal pure returns (string memory) {
        return Strings.toHexString(uint256(uint160(_addr)), 20);
    }

    function asciiBytesToUint(
        bytes memory asciiBytes
    ) public pure returns (uint256) {
        uint256 result = 0;
        for (uint256 i = 0; i < asciiBytes.length; i++) {
            uint256 digit = uint256(uint8(asciiBytes[i])) - 48; // Convert ASCII to digit
            require(digit <= 9, "Invalid ASCII byte");
            result = result * 10 + digit;
        }
        return result;
    }

    function convertAsciiHexToBytes(
        bytes memory asciiHex
    ) public pure returns (bytes memory) {
        require(asciiHex.length % 2 == 0, "Invalid ASCII hex string length");

        bytes memory result = new bytes(asciiHex.length / 2);
        for (uint256 i = 0; i < asciiHex.length / 2; i++) {
            result[i] = byteFromHexChar(asciiHex[2 * i], asciiHex[2 * i + 1]);
        }

        return result;
    }

    function byteFromHexChar(
        bytes1 char1,
        bytes1 char2
    ) internal pure returns (bytes1) {
        uint8 nibble1 = uint8(char1) - (uint8(char1) < 58 ? 48 : 87);
        uint8 nibble2 = uint8(char2) - (uint8(char2) < 58 ? 48 : 87);
        return bytes1(nibble1 * 16 + nibble2);
    }

    function recovers(
        bytes32 hash,
        bytes memory signature
    ) public pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;

        // Check the signature length
        if (signature.length != 65) {
            return (address(0));
        }

        // Divide the signature in r, s and v variables
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }

        // Version of signature should be 27 or 28, but 0 and 1 are also possible versions
        if (v < 27) {
            v += 27;
        }
        // address check = ECDSA.recover(hash, signature);
        // If the version is correct return the signer address
        if (v != 27 && v != 28) {
            return (address(0));
        } else {
            return ecrecover(hash, v, r, s);
        }
    }
}
