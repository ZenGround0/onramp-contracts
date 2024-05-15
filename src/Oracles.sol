// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

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
       require(stringsEqual(_sourceChain_, "FIL"), "Only FIL proofs supported");   
       require(stringsEqual(senderHex, sourceAddress_), "Only sender can execute");
       DataAttestation memory attestation = abi.decode(payload_, (DataAttestation));
       IReceiveAttestation(receiver).proveDataStored(attestation);
    }

    function stringsEqual(string memory a, string memory b) internal pure returns (bool) {
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
}

