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
    proveDataStored
}

// This contract forwards between contracts on the same chain
// Useful for integration tests of flows involving bridges 
// It expects a DealAttestation struct as payload and forwards to
// and L2 on ramp contract at 
contract ForwardingProofMockBridge is IBridgeContract {
    address public owner;
    address public receiver;

    constructor() {
        owner = msg.sender;
    }

    function setReceiver(address receiver_) external {
        require(msg.sender == owner, 'Only owner can set receiver');
        receiver = receiver_;
    }

    function _execute(string calldata sourceChain_, string calldata sourceAddress_, bytes calldata payload_) external override {
   
    }
}

