// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {AxelarExecutable} from "lib/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";


interface IBridgeContract {
    function _execute(string calldata sourceChain_, string calldata sourceAddress_, bytes calldata payload_) external;
}

struct DataAttestation {
    bytes commP;
    int64 duration;
    uint64 FILID;
    uint status;
}

interface IReceiveAttestation {
    function proveDataStored(DataAttestation calldata attestation_) external;
}

// This contract forwards between contracts on the same chain
// Useful for integration tests of flows involving bridges 
// It expects a DealAttestation struct as payload from 
// an address with string encoding == senderHex and forwards to
// an L2 on ramp contract at receiver address
contract ForwardingProofMockBridge is IBridgeContract {
    address public receiver;
    string public senderHex;

    function setSenderReceiver(string calldata senderHex_, address receiver_) external {
        receiver = receiver_;
        senderHex = senderHex_;
    }

    function _execute(string calldata _sourceChain_, string calldata sourceAddress_, bytes calldata payload_) external override {
       require(StringsEqual(_sourceChain_, "FIL"), "Only FIL proofs supported");   
       require(StringsEqual(senderHex, sourceAddress_), "Only sender can execute");
       DataAttestation memory attestation = abi.decode(payload_, (DataAttestation));
       IReceiveAttestation(receiver).proveDataStored(attestation);
    }
}

contract AxelarBridgeDebug is AxelarExecutable {
    event ReceivedAttestation(bytes commP, string sourceAddress);

    constructor(address _gateway) AxelarExecutable(_gateway){}

    function _execute(string calldata, string calldata sourceAddress_, bytes calldata payload_) internal override {
        DataAttestation memory attestation = abi.decode(payload_, (DataAttestation));
        emit ReceivedAttestation(attestation.commP, sourceAddress_);
    }
}

contract AxelarBridge is IBridgeContract {
    address public receiver;
    string public senderHex;

    function setSenderReceiver(string calldata senderHex_, address receiver_) external {
        receiver = receiver_;
        senderHex = senderHex_;
    }

    function _execute(string calldata _sourceChain_, string calldata sourceAddress_, bytes calldata payload_) external override {
       require(StringsEqual(_sourceChain_, "filecoin-2"), "Only filecoin calibration net proofs supported");   
       require(StringsEqual(senderHex, sourceAddress_), "Only registered sender addr can execute");
       DataAttestation memory attestation = abi.decode(payload_, (DataAttestation));
       IReceiveAttestation(receiver).proveDataStored(attestation);
    }
}

contract DebugReceiver is IReceiveAttestation {
    event ReceivedAttestation(bytes Commp);
    function proveDataStored(DataAttestation calldata attestation_) external {
        emit ReceivedAttestation(attestation_.commP);        
    }
}

function StringsEqual(string memory a, string memory b) pure returns (bool) {
    bytes memory aBytes = bytes(a);
    bytes memory bBytes = bytes(b);

    if (aBytes.length != bBytes.length) {
        return false;
    }

    for (uint i = 0; i < aBytes.length; i++) {
        if (aBytes[i] != bBytes[i]) {
            return false;
        }
    }

    return true;
}