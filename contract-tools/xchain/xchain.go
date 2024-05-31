package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/big"
	"os"
	"path/filepath"
	"strconv"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/accounts/keystore"
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
				Value: "~/.xchain/config.json",
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
							auth, err := loadPrivateKey(cfg)
							if err != nil {
								log.Fatal(err)
							}

							// Send Tx
							params, err := packOfferDataParams(cctx, *parsedABI)
							if err != nil {
								log.Fatalf("failed to pack offer data params: %v", err)
							}
							tx, err := onramp.Transact(auth, "offerData", params)
							if err != nil {
								log.Fatalf("failed to send tx: %v", err)
							}
							receipt, err := bind.WaitMined(cctx.Context, client, tx)
							if err != nil {
								log.Fatalf("failed to wait for tx: %v", err)
							}
							log.Printf("Tx %s included: %d", tx.Hash().Hex(), receipt.Status)

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
	ClientAddr    string
	OnRampABIPath string
}

// Mirror OnRamp.sol's `Offer` struct
type Offer struct {
	CommP    []byte
	Duration int64
	Location string
	Amount   *big.Int
	Token    common.Address
}

func packOfferDataParams(cctx *cli.Context, abi abi.ABI) ([]byte, error) {
	commP, err := cid.Decode(cctx.Args().First())
	if err != nil {
		return nil, fmt.Errorf("failed to parse cid %w", err)
	}

	amount := big.NewInt(0).SetUint64(cctx.Uint64(cctx.Args().Get(3)))

	offer := Offer{
		CommP:    commP.Bytes(),
		Location: cctx.Args().Get(1),
		Token:    common.HexToAddress(cctx.Args().Get(2)),
		Amount:   amount,
		Duration: 576_000, // For now set a fixed duration
	}

	return abi.Pack("offerData", offer)
}

// Load Config given path to JSON config file
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

// Load and unlock the keystore with XCHAIN_PASSPHRASE env var
// return a transaction authorizer
func loadPrivateKey(cfg *Config) (*bind.TransactOpts, error) {
	// TODO take parent dir as keystore
	path, err := homedir.Expand(cfg.KeyPath)
	if err != nil {
		return nil, fmt.Errorf("failed to get absolute path: %w", err)
	}
	// Extract the parent directory from the provided key path to use as the keystore directory
	keystorePath := filepath.Dir(path)
	ks := keystore.NewKeyStore(keystorePath, keystore.StandardScryptN, keystore.StandardScryptP)
	a, err := ks.Find(accounts.Account{Address: common.HexToAddress(cfg.ClientAddr)})
	if err != nil {
		return nil, fmt.Errorf("failed to find key %s: %w", cfg.ClientAddr, err)
	}
	if err := ks.Unlock(a, os.Getenv("XCHAIN_PASSPHRASE")); err != nil {
		return nil, fmt.Errorf("failed to unlock keystore: %w", err)
	}
	return bind.NewKeyStoreTransactorWithChainID(ks, a, big.NewInt(int64(cfg.ChainID)))
}

// Load contract abi at the given path
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
