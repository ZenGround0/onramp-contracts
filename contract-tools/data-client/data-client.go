package main

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"os"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ipfs/go-cid"
	"github.com/urfave/cli/v2"
)

type Deal struct {
	CommP    []byte
	Duration int64
	Location string
	Amount   uint64
	Token    common.Address
}

func main() {
	app := &cli.App{
		Name:  "Filecoin Deal Client",
		Usage: "Offers data to the Filecoin network via Ethereum smart contracts",
		Flags: []cli.Flag{
			&cli.StringFlag{
				Name:        "config",
				Usage:       "Path to the configuration file",
				DefaultText: "~/.onramp/config.json",
			},
		},
		Commands: []*cli.Command{
			{
				Name:      "offer-data",
				Usage:     "Offer data by providing file path and deal parameters",
				ArgsUsage: "<commP> <bufferLocation> <token-hex> <token-amount>",
				Action: func(cctx *cli.Context) error {
					cfg, err := readConfig(cctx.String("config"))
					if err != nil {
						log.Fatal(err)
					}

					// Dial network
					client, err := ethclient.Dial(cfg.Api)
					if err != nil {
						log.Fatal(err)
					}

					// Load onramp contract handle
					contractAddress := common.HexToAddress(cfg.OnRampAddress)
					parsedABI, err := abi.JSON(strings.NewReader(cfg.OnRampABI))
					if err != nil {
						log.Fatal(err)
					}
					onramp := bind.NewBoundContract(contractAddress, parsedABI, client, client, client)
					if err != nil {
						log.Fatal(err)
					}

					// Get auth
					privateKey, err := readPrivateKey(cfg.KeyPath)
					if err != nil {
						log.Fatal(err)
					}
					auth, err := bind.NewKeyedTransactorWithChainID(privateKey, big.NewInt(int64(cfg.ChainID)))
					if err != nil {
						log.Fatal(err)
					}

					// Send Tx
					params, err := packOfferDataParams(cctx, parsedABI)
					if err != nil {
						log.Fatal(err)
					}
					tx, err := onramp.Transact(auth, "offerData", params)
					if err != nil {
						log.Fatal(err)
					}
					receipt, err := bind.WaitMined(cctx.Context, client, tx)
					if err != nil {
						log.Fatal(err)
					}
					log.Printf("Tx %s mined: %d", tx.Hash().Hex(), receipt.Status)

					return nil
				},
			},
		},
	}

	err := app.Run(os.Args)
	if err != nil {
		log.Fatal(err)
	}
}

type Config struct {
	ChainID       int
	Api           string
	OnRampAddress string
	KeyPath       string
	OnRampABI     string
	ClientAddr    string
}

// Mirror OnRamp.sol's `Offer` struct
type Offer struct {
	CommP    []byte
	Duration int64
	Location string
	Amount   uint64
	Token    common.Address
}

func packOfferDataParams(cctx *cli.Context, abi abi.ABI) ([]byte, error) {
	commP, err := cid.Decode(cctx.Args().First())
	if err != nil {
		return nil, fmt.Errorf("failed to parse cid %w", err)
	}

	offer := Offer{
		CommP:    commP.Bytes(),
		Location: cctx.Args().Get(1),
		Token:    common.HexToAddress(cctx.Args().Get(2)),
		Amount:   cctx.Uint64(cctx.Args().Get(3)),
		Duration: 576_000, // For now set a fixed duration
	}

	return abi.Pack("offerData", offer)
}

// Read JSON config file given path and return Config object
func readConfig(path string) (*Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open config file: %w", err)
	}
	defer file.Close()

	decoder := json.NewDecoder(file)
	var cfg Config
	err = decoder.Decode(&cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to decode config file: %v", err)
	}
	return &cfg, nil
}

// Read private key from file and return as an ECDSA private key
func readPrivateKey(path string) (*ecdsa.PrivateKey, error) {
	b64KeyBs, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	b64Key := string(b64KeyBs)

	// Decode the base64 string to bytes
	keyBytes, err := base64.StdEncoding.DecodeString(b64Key)
	if err != nil {
		return nil, err
	}

	// Parse the bytes to an ECDSA private key
	privateKey, err := x509.ParseECPrivateKey(keyBytes)
	if err != nil {
		return nil, err
	}

	return privateKey, nil
}
