package main

import (
	"context"
	"encoding/hex"
	"fmt"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/filecoin-project/go-address"
	"github.com/stretchr/testify/assert"
)

// Test function to test chainID encoding
func TestChainIdEncoding(t *testing.T) {
	configPath := "~/.xchain/config.json" // Replace with the actual path to your config file

	config, err := LoadConfig(configPath); 
	if err != nil {
		t.Fatalf("failed to unmarshal config: %v", err)
	}

	// Connect to the Ethereum client
	client, err := ethclient.Dial(config.Api)
	if err != nil {
		t.Fatalf("failed to connect to the Ethereum client: %v", err)
	}

	// Query the chain ID
	chainID, err := client.ChainID(context.Background())
	if err != nil {
		t.Fatalf("failed to get chain ID: %v", err)
	}

	// Encode the chainID
	encodedChainID, err := encodeChainID(chainID)
	if err != nil {
		t.Fatalf("failed to encode chainID: %v", err)
	}

	fmt.Println("Encoded chainID: ", encodedChainID)
	fmt.Println("chainID: ", chainID)
	hexEncodedChainID := hex.EncodeToString(encodedChainID)
    fmt.Printf("Encoded ChainID in Hex: %s\n", hexEncodedChainID)
	decodedChainID, err := decodeChainID(encodedChainID)
	if err != nil {
		t.Fatalf("failed to decode chainID: %v", err)
	}
	fmt.Println("Decoded chainID: ", decodedChainID)
	assert.Equal(t, decodedChainID, chainID, "Encoded chainID does not match expected value")
}

func decodeChainID(data []byte) (*big.Int, error) {
    // Define the ABI arguments
    uint256Type, err := abi.NewType("uint256", "", nil)
    if err != nil {
        return nil, fmt.Errorf("failed to create uint256 type: %w", err)
    }

    arguments := abi.Arguments{
        {Type: uint256Type}, // chainID is a uint256 in Solidity
    }

    // Unpack the byte array into a slice of interface{}
    unpacked, err := arguments.Unpack(data)
    if err != nil {
        return nil, fmt.Errorf("failed to decode chainID: %w", err)
    }

    // Extract the chainID from the unpacked slice
    if len(unpacked) == 0 {
        return nil, fmt.Errorf("no data unpacked")
    }

    chainID, ok := unpacked[0].(*big.Int)
    if !ok {
        return nil, fmt.Errorf("failed to assert type to *big.Int")
    }

    return chainID, nil
}

func TestAddrToBytes(t *testing.T) {
	    // Example address (replace with actual address)
		addr, err := address.NewFromString("t0116147")
		if err != nil {
			fmt.Println("Error creating address:", err)
			return
		}
	
		// Get the byte representation of the address
		addrBytes := addr.Bytes()
	
		// Encode the byte representation to a hexadecimal string
		addrHex := hex.EncodeToString(addrBytes)
		
		fmt.Println("Address in bytes: ", addrBytes)
		fmt.Println("Address in hex: ", addrHex)
		assert.Equal(t, addrHex, "00b38b07", "Address does not match expected value")
	}