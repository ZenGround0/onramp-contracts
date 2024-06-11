package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/big"
	"os"
	"strconv"
	"strings"

	"github.com/ethereum/go-ethereum"
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
					cfg, err := LoadConfig(cctx.String("config"))
					if err != nil {
						log.Fatal(err)
					}

					// Dial network
					client, err := ethclient.Dial(cfg.Api)
					if err != nil {
						log.Fatal(err)
					}

					contractAddress := common.HexToAddress(cfg.OnRampAddress)
					parsedABI, err := LoadAbi(cfg.OnRampABIPath)
					if err != nil {
						log.Fatal(err)
					}

					// Listen for notifications
					query := ethereum.FilterQuery{
						Addresses: []common.Address{contractAddress},
						Topics:    [][]common.Hash{{parsedABI.Events["DataReady"].ID}},
					}

					errQ := SubscribeQuery(cctx.Context, client, contractAddress, *parsedABI, query)
					for errQ == nil || strings.Contains(errQ.Error(), "read tcp") {
						log.Printf("ignoring mystery error: %s", errQ)
						errQ = SubscribeQuery(cctx.Context, client, contractAddress, *parsedABI, query)
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
						ArgsUsage: "<commP> <size> <bufferLocation> <token-hex> <token-amount>",
						Action: func(cctx *cli.Context) error {
							cfg, err := LoadConfig(cctx.String("config"))
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
							parsedABI, err := LoadAbi(cfg.OnRampABIPath)
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
							offer, err := MakeOffer(
								cctx.Args().First(),
								cctx.Uint64(cctx.Args().Get(1)),
								cctx.Args().Get(2),
								cctx.Args().Get(3),
								cctx.Uint64(cctx.Args().Get(4)),
								*parsedABI,
							)
							if err != nil {
								log.Fatalf("failed to pack offer data params: %v", err)
							}
							tx, err := onramp.Transact(auth, "offerData", offer)
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
	Size     uint64
	Location string
	Amount   *big.Int
	Token    common.Address
}

func SubscribeQuery(ctx context.Context, client *ethclient.Client, contractAddress common.Address, parsedABI abi.ABI, query ethereum.FilterQuery) error {
	logs := make(chan types.Log)
	log.Printf("Listening for data ready events on %s\n", contractAddress.Hex())
	sub, err := client.SubscribeFilterLogs(ctx, query, logs)
	if err != nil {
		return err
	}
	defer sub.Unsubscribe()
LOOP:
	for {
		select {
		case <-ctx.Done():
			break LOOP
		case err := <-sub.Err():
			return err
		case vLog := <-logs:
			fmt.Println("Log Data:", vLog.Data)
			event, err := parsedABI.Unpack("DataReady", vLog.Data)
			if err != nil {
				return err
			}
			fmt.Println("Event Parsed:", event)
		}
	}
	return nil
}

func MakeOffer(cidStr string, size uint64, location string, token string, amount uint64, abi abi.ABI) (*Offer, error) {
	commP, err := cid.Decode(cidStr)
	if err != nil {
		return nil, fmt.Errorf("failed to parse cid %w", err)
	}

	amountBig := big.NewInt(0).SetUint64(amount)

	offer := Offer{
		CommP:    commP.Bytes(),
		Location: location,
		Token:    common.HexToAddress(token),
		Amount:   amountBig,
		Size:     size,
	}

	return &offer, nil
}

// Load Config given path to JSON config file
func LoadConfig(path string) (*Config, error) {
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
	path, err := homedir.Expand(cfg.KeyPath)
	if err != nil {
		return nil, fmt.Errorf("failed to get absolute path: %w", err)
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open keystore file: %w", err)
	}
	defer file.Close()
	keyJSON, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read key store bytes from file: %w", err)
	}

	// Create a temporary directory to initialize the per-call keystore
	tempDir, err := os.MkdirTemp("", "xchain-tmp")
	if err != nil {
		return nil, fmt.Errorf("failed to create temporary directory: %w", err)
	}
	defer os.RemoveAll(tempDir)
	ks := keystore.NewKeyStore(tempDir, keystore.StandardScryptN, keystore.StandardScryptP)

	// Import existing key
	a, err := ks.Import(keyJSON, os.Getenv("XCHAIN_PASSPHRASE"), os.Getenv("XCHAIN_PASSPHRASE"))
	if err != nil {
		return nil, fmt.Errorf("failed to import key %s: %w", cfg.ClientAddr, err)
	}
	if err := ks.Unlock(a, os.Getenv("XCHAIN_PASSPHRASE")); err != nil {
		return nil, fmt.Errorf("failed to unlock keystore: %w", err)
	}
	return bind.NewKeyStoreTransactorWithChainID(ks, a, big.NewInt(int64(cfg.ChainID)))
}

// Load contract abi at the given path
func LoadAbi(path string) (*abi.ABI, error) {
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
