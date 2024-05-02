// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface OnRamp {
    struct DataRef {
        bytes32 commP;
        int64 storage_duration;
        string location;
        uint64 value;
    }

    type DataRefID is uint64;

    event DataReady(DataRef ref, DataRefID id);

    function offer_data(DataRef calldata ref, uint256 amount, IERC20 token) external payable returns (DataRefID);
    function verify_data_stored(DataRefID id) external returns (bool);
    function prove_data_stored(DataRefID id, bytes calldata proof) external;
}

contract OnRampContract is OnRamp {
    uint64 private nextId = 1;
    mapping(uint64 => DataRef) public dataRefs;

    function offer_data(DataRef calldata ref, uint256 amount, IERC20 token) external payable override returns (DataRefID) {
        require(token.transferFrom(msg.sender, address(this), amount), "Payment transfer failed");

        DataRefID id = nextId++;
        dataRefs[id] = ref;

        emit DataReady(ref, id);
        return id;
    }

    function verify_data_stored(DataRefID id) external override returns (bool) {
        // Implementation needed
        return true;
    }

    function prove_data_stored(DataRefID id, bytes calldata proof) external override {
        // Implementation needed
    }
}