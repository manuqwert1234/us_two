package raft

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"

	"github.com/adithyanca/titan/internal/logger"
	hraft "github.com/hashicorp/raft"
	boltdb "github.com/hashicorp/raft-boltdb/v2"
)

var log = logger.New("Raft")

// ClusterConfig holds the configuration for a Raft node.
type ClusterConfig struct {
	NodeID    string
	BindAddr  string   // e.g., "0.0.0.0:50052"
	DataDir   string   // directory for Raft state
	Bootstrap bool     // true for the first node
	Peers     []string // peer addresses for join
}

// Node wraps a hashicorp/raft instance.
type Node struct {
	raft   *hraft.Raft
	config *ClusterConfig
}

// FSM (Finite State Machine) implements the raft.FSM interface.
// It stores cluster state that gets replicated across all nodes.
type FSM struct {
	state map[string]string
}

// LogEntry is the data format for Raft log entries.
type LogEntry struct {
	Type  string `json:"type"`  // "set", "delete"
	Key   string `json:"key"`
	Value string `json:"value"`
}

func NewFSM() *FSM {
	return &FSM{state: make(map[string]string)}
}

// Apply is called when a log entry is committed. It applies the entry to the FSM.
func (f *FSM) Apply(logEntry *hraft.Log) interface{} {
	var entry LogEntry
	if err := json.Unmarshal(logEntry.Data, &entry); err != nil {
		log.Error("Failed to unmarshal log entry: %v", err)
		return err
	}

	switch entry.Type {
	case "set":
		f.state[entry.Key] = entry.Value
		log.Debug("FSM: set %s = %s", entry.Key, entry.Value)
	case "delete":
		delete(f.state, entry.Key)
		log.Debug("FSM: delete %s", entry.Key)
	}
	return nil
}

// Snapshot returns an FSM snapshot for Raft snapshotting.
func (f *FSM) Snapshot() (hraft.FSMSnapshot, error) {
	// Copy state
	copied := make(map[string]string)
	for k, v := range f.state {
		copied[k] = v
	}
	return &fsmSnapshot{state: copied}, nil
}

// Restore restores the FSM from a snapshot.
func (f *FSM) Restore(rc io.ReadCloser) error {
	defer rc.Close()
	return json.NewDecoder(rc).Decode(&f.state)
}

type fsmSnapshot struct {
	state map[string]string
}

func (s *fsmSnapshot) Persist(sink hraft.SnapshotSink) error {
	data, err := json.Marshal(s.state)
	if err != nil {
		sink.Cancel()
		return err
	}
	if _, err := sink.Write(data); err != nil {
		sink.Cancel()
		return err
	}
	return sink.Close()
}

func (s *fsmSnapshot) Release() {}

// NewNode creates and starts a new Raft node.
func NewNode(cfg *ClusterConfig) (*Node, error) {
	// Create data directory
	if err := os.MkdirAll(cfg.DataDir, 0700); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}

	// Raft configuration
	raftConfig := hraft.DefaultConfig()
	raftConfig.LocalID = hraft.ServerID(cfg.NodeID)
	raftConfig.HeartbeatTimeout = 1000 * time.Millisecond
	raftConfig.ElectionTimeout = 1000 * time.Millisecond
	raftConfig.CommitTimeout = 500 * time.Millisecond
	raftConfig.SnapshotInterval = 30 * time.Second
	raftConfig.SnapshotThreshold = 100

	// TCP transport
	addr, err := net.ResolveTCPAddr("tcp", cfg.BindAddr)
	if err != nil {
		return nil, fmt.Errorf("resolve addr: %w", err)
	}
	transport, err := hraft.NewTCPTransport(cfg.BindAddr, addr, 3, 10*time.Second, os.Stderr)
	if err != nil {
		return nil, fmt.Errorf("create transport: %w", err)
	}

	// Log store & stable store (BoltDB)
	boltPath := filepath.Join(cfg.DataDir, "raft.db")
	store, err := boltdb.NewBoltStore(boltPath)
	if err != nil {
		return nil, fmt.Errorf("create bolt store: %w", err)
	}

	// Snapshot store
	snapshots, err := hraft.NewFileSnapshotStore(cfg.DataDir, 2, os.Stderr)
	if err != nil {
		return nil, fmt.Errorf("create snapshot store: %w", err)
	}

	fsm := NewFSM()

	// Create Raft instance
	r, err := hraft.NewRaft(raftConfig, fsm, store, store, snapshots, transport)
	if err != nil {
		return nil, fmt.Errorf("create raft: %w", err)
	}

	// Bootstrap if this is the first node
	if cfg.Bootstrap {
		config := hraft.Configuration{
			Servers: []hraft.Server{
				{
					ID:      hraft.ServerID(cfg.NodeID),
					Address: hraft.ServerAddress(cfg.BindAddr),
				},
			},
		}
		f := r.BootstrapCluster(config)
		if err := f.Error(); err != nil && err != hraft.ErrCantBootstrap {
			log.Warn("Bootstrap: %v (may already be bootstrapped)", err)
		}
	}

	node := &Node{raft: r, config: cfg}

	// Add peers
	for _, peer := range cfg.Peers {
		if peer == cfg.BindAddr {
			continue
		}
		peerID := hraft.ServerID(peer)
		f := r.AddVoter(peerID, hraft.ServerAddress(peer), 0, 5*time.Second)
		if err := f.Error(); err != nil {
			log.Warn("AddVoter %s: %v", peer, err)
		}
	}

	log.Info("Raft node %s started (bootstrap=%v)", cfg.NodeID, cfg.Bootstrap)
	return node, nil
}

// IsLeader returns true if this node is the current Raft leader.
func (n *Node) IsLeader() bool {
	return n.raft.State() == hraft.Leader
}

// LeaderAddr returns the address of the current leader.
func (n *Node) LeaderAddr() string {
	addr, _ := n.raft.LeaderWithID()
	return string(addr)
}

// Apply applies a log entry to the Raft cluster (leader only).
func (n *Node) Apply(entry LogEntry) error {
	if !n.IsLeader() {
		return fmt.Errorf("not leader, leader is: %s", n.LeaderAddr())
	}

	data, err := json.Marshal(entry)
	if err != nil {
		return err
	}

	f := n.raft.Apply(data, 5*time.Second)
	return f.Error()
}

// Shutdown gracefully shuts down the Raft node.
func (n *Node) Shutdown() error {
	f := n.raft.Shutdown()
	return f.Error()
}
