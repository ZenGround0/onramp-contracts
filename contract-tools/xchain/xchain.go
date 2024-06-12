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

	"golang.org/x/sync/errgroup"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/accounts/keystore"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/filecoin-project/go-data-segment/datasegment"
	"github.com/filecoin-project/go-data-segment/merkletree"
	filabi "github.com/filecoin-project/go-state-types/abi"
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

					ot, err := NewOfferTaker(cfg)
					if err != nil {
						return err
					}
					err = ot.run(cctx.Context)
					if err != nil {
						log.Fatalf("failure while running offer taker: %s", err)
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
								cctx.Args().Get(1),
								cctx.Args().Get(2),
								cctx.Args().Get(3),
								cctx.Args().Get(4),
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
	CommP    []uint8        `json:"commP"`
	Size     uint64         `json:"size"`
	Location string         `json:"location"`
	Amount   *big.Int       `json:"amount"`
	Token    common.Address `json:"token"`
}

func (o *Offer) Piece() (filabi.PieceInfo, error) {
	pps := filabi.PaddedPieceSize(o.Size)
	if err := pps.Validate(); err != nil {
		return filabi.PieceInfo{}, err
	}
	_, c, err := cid.CidFromBytes(o.CommP)
	if err != nil {
		return filabi.PieceInfo{}, err
	}
	return filabi.PieceInfo{
		Size:     pps,
		PieceCID: c,
	}, nil
}

type offerTaker struct {
	client         *ethclient.Client   // raw client for log subscriptions
	onramp         *bind.BoundContract // onramp binding over raw client for message sending
	auth           *bind.TransactOpts  // auth for message sending
	abi            *abi.ABI            // onramp abi for log subscription and message sending
	onrampAddr     common.Address      // onramp address for log subscription
	ch             chan DataReadyEvent // pass events to seperate goroutine for processing
	targetDealSize uint64              // how big aggregates should be
}

func NewOfferTaker(cfg *Config) (*offerTaker, error) {
	client, err := ethclient.Dial(cfg.Api)
	if err != nil {
		log.Fatal(err)
	}

	parsedABI, err := LoadAbi(cfg.OnRampABIPath)
	if err != nil {
		return nil, err
	}
	contractAddress := common.HexToAddress(cfg.OnRampAddress)
	onramp := bind.NewBoundContract(contractAddress, *parsedABI, client, client, client)

	auth, err := loadPrivateKey(cfg)
	if err != nil {
		return nil, err
	}

	// TODO this should be specified in config
	targetSize := uint64(2 << 10)
	return &offerTaker{
		client:         client,
		onramp:         onramp,
		onrampAddr:     contractAddress,
		auth:           auth,
		ch:             make(chan DataReadyEvent, 1024), // buffer many events since consumer sometimes waits for chain
		abi:            parsedABI,
		targetDealSize: targetSize,
	}, nil
}

// Run the two offerTaker persistant process
//  1. a goroutine listening for new DataReady events
//  2. a goroutine collecting data and aggregating before commiting
//     to store and sending to filecoin boost
func (ot *offerTaker) run(ctx context.Context) error {

	g, ctx := errgroup.WithContext(ctx)

	// Start listening for events
	// New DataReady events are passed through the channel to aggregation handling
	g.Go(func() error {
		query := ethereum.FilterQuery{
			Addresses: []common.Address{ot.onrampAddr},
			Topics:    [][]common.Hash{{ot.abi.Events["DataReady"].ID}},
		}

		err := ot.SubscribeQuery(ctx, query)
		for err == nil || strings.Contains(err.Error(), "read tcp") {
			if err != nil {
				log.Printf("ignoring mystery error: %s", err)
			}
			if ctx.Err() != nil {
				err = ctx.Err()
				break
			}
			err = ot.SubscribeQuery(ctx, query)
		}
		return err
	})

	// Start aggregatation event handling
	g.Go(func() error {
		return ot.runAggregate(ctx)
	})

	return g.Wait()
}

const (
	// PODSI aggregation uses 64 extra bytes per piece
	pieceOverhead = uint64(64)
	// Piece CID of small valid car that must be prepended to the aggregation for deal acceptance
	prefixCARCid = "baga6ea4seaqmazvw4o5nc7ht6emz2n2kb36kzbib3czzwrx5dsz5nog65uxwupq"
	// Size of the prefix car in bytes
	prefixCARSizePadded = uint64(256)
)

func (ot *offerTaker) runAggregate(ctx context.Context) error {
	pending := make([]DataReadyEvent, 0, 256) // pieces being aggregated, flushed upon commitment
	total := uint64(0)
	prefixPiece := filabi.PieceInfo{
		Size:     filabi.PaddedPieceSize(prefixCARSizePadded),
		PieceCID: cid.MustParse(prefixCARCid),
	}

	for {
		select {
		case <-ctx.Done():
			return nil
		case event := <-ot.ch:
			// Check if the offer is too big to fit in a valid aggregate on its own
			// TODO: as referenced below there must be a better way when we introspect on the gory details of NewAggregate
			latestPiece, err := event.Offer.Piece()
			if err != nil {
				log.Printf("skipping offer %d, size %d not valid padded piece size ", event.OfferID, event.Offer.Size)
				continue
			}
			_, err = datasegment.NewAggregate(filabi.PaddedPieceSize(ot.targetDealSize), []filabi.PieceInfo{
				prefixPiece,
				latestPiece,
			})
			if err != nil {
				log.Printf("skipping offer %d, size %d exceeds max PODSI packable size", event.OfferID, event.Offer.Size)
				continue
			}
			// TODO: in production we'll maybe want to move data from buffer before we commit to storing it.

			// TODO: Unsorted greedy is a very naive knapsack strategy, production will want something better
			// TODO: doing all the work of creating an aggregate for every new offer is quite wasteful
			//      there must be a cheaper way to do this, but for now it is the most expediant without learning
			//      all the gory edge cases in NewAggregate

			// Turn offers into datasegment pieces
			pieces := make([]filabi.PieceInfo, len(pending)+1)
			for i, event := range pending {
				piece, err := event.Offer.Piece()
				if err != nil {
					return err
				}
				pieces[i] = piece
			}

			pieces[len(pending)] = latestPiece
			// aggregate
			aggregatePieces := append([]filabi.PieceInfo{
				prefixPiece,
			}, pieces...)
			_, err = datasegment.NewAggregate(filabi.PaddedPieceSize(ot.targetDealSize), aggregatePieces)
			if err != nil { // we've overshot, lets commit to just pieces in pending
				total = 0
				// Remove the latest offer which took us over
				pieces = pieces[:len(pieces)-1]
				aggregatePieces = aggregatePieces[:len(aggregatePieces)-1]
				a, err := datasegment.NewAggregate(filabi.PaddedPieceSize(ot.targetDealSize), aggregatePieces)
				if err != nil {
					return fmt.Errorf("failed to create aggregate from pending, should not be reachable: %w", err)
				}

				inclProofs := make([]merkletree.ProofData, len(pieces))
				ids := make([]uint64, len(pieces))
				for i, piece := range pieces {
					podsi, err := a.ProofForPieceInfo(piece)
					if err != nil {
						return err
					}
					ids[i] = pending[i].OfferID
					inclProofs[i] = podsi.ProofSubtree // Only do data proofs on chain for now not index proofs
				}
				aggCommp, err := a.PieceCID()
				if err != nil {
					return err
				}
				tx, err := ot.onramp.Transact(ot.auth, "commitAggregate", aggCommp.Bytes(), ids, inclProofs, common.HexToAddress("0x0"))
				if err != nil {
					return err
				}
				receipt, err := bind.WaitMined(ctx, ot.client, tx)
				if err != nil {
					return err
				}
				log.Printf("Tx %s committing aggregate commp %s included: %d", tx.Hash().Hex(), aggCommp.String(), receipt.Status)

				// Reset queue to empty, add the event that triggered aggregation
				pending = pending[:0]
				pending = append(pending, event)

			} else {
				total += event.Offer.Size
				pending = append(pending, event)
				log.Printf("Offer %d added. %d offers pending aggregation with total size=%d\n", event.OfferID, len(pending), total)
			}
		}
	}
}

type CommitAggregateParams struct {
	Aggregate       []byte
	ClaimedIDs      []uint64
	InclusionProofs []merkletree.ProofData
	PayoutAddr      common.Address
}

func (ot *offerTaker) SubscribeQuery(ctx context.Context, query ethereum.FilterQuery) error {
	logs := make(chan types.Log)
	log.Printf("Listening for data ready events on %s\n", ot.onrampAddr.Hex())
	sub, err := ot.client.SubscribeFilterLogs(ctx, query, logs)
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
			event, err := parseDataReadyEvent(vLog, ot.abi)
			if err != nil {
				return err
			}
			log.Printf("Sending offer %d for aggregation\n", event.OfferID)
			// This is where we should make packing decisions.
			// In the current prototype we accept all offers regardless
			// of payment type, amount or duration
			ot.ch <- *event
		}
	}
	return nil
}

// Define a Go struct to match the DataReady event from the OnRamp contract
type DataReadyEvent struct {
	Offer   Offer
	OfferID uint64
}

// Function to parse the DataReady event from log data
func parseDataReadyEvent(log types.Log, abi *abi.ABI) (*DataReadyEvent, error) {
	eventData, err := abi.Unpack("DataReady", log.Data)
	if err != nil {
		return nil, fmt.Errorf("failed to unpack 'DataReady' event: %w", err)
	}

	// Assuming eventData is correctly ordered as per the event definition in the Solidity contract
	if len(eventData) != 2 {
		return nil, fmt.Errorf("unexpected number of fields for 'DataReady' event: got %d, want 2", len(eventData))
	}

	offerID, ok := eventData[1].(uint64)
	if !ok {
		return nil, fmt.Errorf("invalid type for offerID, expected uint64, got %T", eventData[1])
	}

	offerDataRaw := eventData[0]
	// JSON round trip to deserialize to offer
	bs, err := json.Marshal(offerDataRaw)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal raw offer data to json: %w", err)
	}
	var offer Offer
	err = json.Unmarshal(bs, &offer)
	if err != nil {
		return nil, fmt.Errorf("failed to unmarshal raw offer data to nice offer struct: %w", err)
	}

	return &DataReadyEvent{
		OfferID: offerID,
		Offer:   offer,
	}, nil
}

func HandleOffer(offer *Offer) error {
	return nil
}

func MakeOffer(cidStr string, sizeStr string, location string, token string, amountStr string, abi abi.ABI) (*Offer, error) {
	commP, err := cid.Decode(cidStr)
	if err != nil {
		return nil, fmt.Errorf("failed to parse cid %w", err)
	}

	size, err := strconv.Atoi(sizeStr)
	if err != nil {
		return nil, err
	}
	amount, err := strconv.Atoi(amountStr)
	if err != nil {
		return nil, err
	}

	amountBig := big.NewInt(0).SetUint64(uint64(amount))

	offer := Offer{
		CommP:    commP.Bytes(),
		Location: location,
		Token:    common.HexToAddress(token),
		Amount:   amountBig,
		Size:     uint64(size),
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
