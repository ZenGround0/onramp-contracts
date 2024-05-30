package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/big"
	"os"
	"strconv"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ipfs/go-cid"
	"github.com/mitchellh/go-homedir"
	"github.com/urfave/cli/v2"
)

func main() {
	app := &cli.App{
		Name:        "xchain",
		Description: "Filecoin Xchain Data Services",
		Usage:       "Export filecoin data storage to any blockchain",
		Flags: []cli.Flag{
			&cli.StringFlag{
				Name:  "config",
				Usage: "Path to the configuration file",
				Value: "~/.onramp/config.json",
			},
		},
		Commands: []*cli.Command{
			{
				Name:  "daemon",
				Usage: "Start the xchain adapter daemon",
				Action: func(cctx *cli.Context) error {
					cfg, err := loadConfig(cctx.String("config"))
					if err != nil {
						log.Fatal(err)
					}

					// Dial network
					client, err := ethclient.Dial(cfg.Api)
					if err != nil {
						log.Fatal(err)
					}

					contractAddress := common.HexToAddress(cfg.OnRampAddress)
					parsedABI, err := loadAbi(cfg.OnRampABIPath)
					if err != nil {
						log.Fatal(err)
					}

					// Listen for notifications
					query := ethereum.FilterQuery{
						Addresses: []common.Address{contractAddress},
						Topics:    [][]common.Hash{{parsedABI.Events["DataReady"].ID}},
					}

					logs := make(chan types.Log)
					sub, err := client.SubscribeFilterLogs(context.Background(), query, logs)
					if err != nil {
						log.Fatal(err)
					}
				LOOP:
					for {
						select {
						case <-cctx.Done():
							break LOOP
						case err := <-sub.Err():
							log.Fatal(err)
						case vLog := <-logs:
							fmt.Println("Log Data:", vLog.Data)
							event, err := parsedABI.Unpack("DataReady", vLog.Data)
							if err != nil {
								log.Fatal(err)
							}
							fmt.Println("Event Parsed:", event)
						}
					}

					return nil
				},
			},
			{
				Name:  "client",
				Usage: "Send data from cross chain to filecoin",
				Subcommands: []*cli.Command{
					{
						Name:      "offer",
						Usage:     "Offer data by providing file and payment parameters",
						ArgsUsage: "<commP> <bufferLocation> <token-hex> <token-amount>",
						Action: func(cctx *cli.Context) error {
							cfg, err := loadConfig(cctx.String("config"))
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
							parsedABI, err := loadAbi(cfg.OnRampABIPath)
							if err != nil {
								log.Fatal(err)
							}
							onramp := bind.NewBoundContract(contractAddress, *parsedABI, client, client, client)
							if err != nil {
								log.Fatal(err)
							}

							// Get auth
							privateKey, err := loadPrivateKey(cfg.KeyPath)
							if err != nil {
								log.Fatal(err)
							}
							auth, err := bind.NewKeyedTransactorWithChainID(privateKey, big.NewInt(int64(cfg.ChainID)))
							if err != nil {
								log.Fatal(err)
							}

							// Send Tx
							params, err := packOfferDataParams(cctx, *parsedABI)
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
			},
			{
				Name:  "buffer",
				Usage: "Store data between offer and commit",
				Subcommands: []*cli.Command{
					{
						Name:  "put",
						Usage: "Put content into the buffer from stdin",
						Action: func(c *cli.Context) error {
							bfs := NewBufferFS()
							// Directly pass os.Stdin to the Put method
							id, err := bfs.Put(os.Stdin)
							if err != nil {
								return err
							}
							fmt.Printf("Content stored with ID: %d\n", id)
							return nil
						},
					},
					{
						Name:  "get",
						Usage: "Get a file from the buffer by ID",
						Action: func(c *cli.Context) error {
							if c.Args().Len() < 1 {
								return fmt.Errorf("please specify the file ID")
							}
							id, err := strconv.Atoi(c.Args().Get(0))
							if err != nil {
								return fmt.Errorf("invalid ID format")
							}
							bfs := NewBufferFS()
							reader, err := bfs.Get(id)
							if err != nil {
								return err
							}
							_, err = io.Copy(os.Stdout, reader)
							if err != nil {
								return err
							}
							return nil
						},
					},
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
	OnRampABIPath string
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
func loadConfig(path string) (*Config, error) {
	path, err := homedir.Expand(path)
	if err != nil {
		return nil, fmt.Errorf("failed to get absolute path: %w", err)
	}

	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open config file: %w", err)
	}
	defer file.Close()

	bs, err := io.ReadAll(file)
	if err != nil {
		return nil, fmt.Errorf("failed to read config bytes from file: %w", err)
	}
	var cfg []Config

	err = json.Unmarshal(bs, &cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to decode config file: %v", err)
	}
	if len(cfg) != 1 {
		return nil, fmt.Errorf("expected 1 config, got %d", len(cfg))
	}
	return &cfg[0], nil
}

// Read private key from file and return as an ECDSA private key
func loadPrivateKey(path string) (*ecdsa.PrivateKey, error) {
	path, err := homedir.Expand(path)
	if err != nil {
		return nil, fmt.Errorf("failed to get absolute path: %w", err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var keyJson struct {
		Type       string
		PrivateKey string
	}
	err = json.Unmarshal(raw, &keyJson)
	if err != nil {
		return nil, err
	}
	b64Key := keyJson.PrivateKey

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

func loadAbi(path string) (*abi.ABI, error) {
	path, err := homedir.Expand(path)
	if err != nil {
		return nil, fmt.Errorf("failed to get absolute path: %w", err)
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open abi file: %w", err)
	}
	parsedABI, err := abi.JSON(f)
	if err != nil {
		return nil, fmt.Errorf("failed to parse abi: %w", err)
	}
	return &parsedABI, nil
}
