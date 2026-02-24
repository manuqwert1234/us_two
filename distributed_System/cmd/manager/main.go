package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/adithyanca/titan/internal/dashboard"
	"github.com/adithyanca/titan/internal/logger"
	"github.com/adithyanca/titan/internal/manager"
	titanraft "github.com/adithyanca/titan/internal/raft"
	"github.com/adithyanca/titan/internal/store"
	"github.com/adithyanca/titan/internal/tlsconfig"
	pb "github.com/adithyanca/titan/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	gmd "google.golang.org/grpc/metadata"
	"google.golang.org/grpc/reflection"
	"google.golang.org/grpc/status"
)

var log = logger.New("Main")

func main() {
	port := flag.Int("port", 50051, "gRPC listen port")
	dashPort := flag.Int("dash-port", 8080, "Web dashboard HTTP port")
	logLevel := flag.String("log-level", "info", "Log level (debug, info, warn, error)")
	apiToken := flag.String("api-token", "", "API token for client authentication (empty = no auth)")

	// TLS flags
	useTLS := flag.Bool("tls", false, "Enable mTLS")
	tlsCert := flag.String("tls-cert", "certs/server.pem", "TLS certificate file")
	tlsKey := flag.String("tls-key", "certs/server-key.pem", "TLS private key file")
	tlsCA := flag.String("tls-ca", "certs/ca.pem", "TLS CA certificate file")

	// Raft flags
	useRaft := flag.Bool("raft", false, "Enable Raft consensus for multi-manager HA")
	raftNodeID := flag.String("raft-id", "", "Raft node ID (required if --raft)")
	raftBind := flag.String("raft-bind", "0.0.0.0:50052", "Raft transport bind address")
	raftDir := flag.String("raft-dir", "data/raft", "Raft data directory")
	raftBootstrap := flag.Bool("raft-bootstrap", false, "Bootstrap Raft cluster (first node only)")

	// PostgreSQL flags
	pgDSN := flag.String("pg-dsn", "", "PostgreSQL connection string (empty = in-memory)")

	flag.Parse()

	log.SetLevel(logger.ParseLevel(*logLevel))

	// ─── Server init ──────────────────────────────────────────────────────
	srv := manager.NewServer()

	// ─── PostgreSQL (optional) ────────────────────────────────────────────
	if *pgDSN != "" {
		pgStore, err := store.NewPostgresStore(*pgDSN)
		if err != nil {
			log.Fatal("PostgreSQL connection failed: %v", err)
		}
		defer pgStore.Close()
		log.Info("PostgreSQL persistence enabled — tasks written to Postgres")
		srv = manager.NewServerWithStore(pgStore)
	}

	// ─── Raft (optional) ──────────────────────────────────────────────────
	if *useRaft {
		if *raftNodeID == "" {
			log.Fatal("--raft-id is required when --raft is enabled")
		}
		raftNode, err := titanraft.NewNode(&titanraft.ClusterConfig{
			NodeID:    *raftNodeID,
			BindAddr:  *raftBind,
			DataDir:   *raftDir,
			Bootstrap: *raftBootstrap,
		})
		if err != nil {
			log.Fatal("Raft initialization failed: %v", err)
		}
		defer raftNode.Shutdown()

		if raftNode.IsLeader() {
			log.Info("This node is the Raft LEADER")
		} else {
			log.Info("This node is a Raft FOLLOWER (leader: %s)", raftNode.LeaderAddr())
		}
	}

	addr := fmt.Sprintf("0.0.0.0:%d", *port)
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal("Failed to listen on %s: %v", addr, err)
	}

	// Build interceptor chain
	interceptors := []grpc.UnaryServerInterceptor{loggingInterceptor}
	if *apiToken != "" {
		interceptors = append(interceptors, authInterceptor(*apiToken))
		log.Info("API token authentication enabled.")
	}

	// Build server options
	opts := []grpc.ServerOption{
		grpc.ChainUnaryInterceptor(interceptors...),
	}

	// Add TLS if enabled
	if *useTLS {
		creds, err := tlsconfig.ServerCredentials(*tlsCert, *tlsKey, *tlsCA)
		if err != nil {
			log.Fatal("Failed to load TLS credentials: %v", err)
		}
		opts = append(opts, grpc.Creds(creds))
		log.Info("mTLS enabled (cert=%s)", *tlsCert)
	}

	grpcServer := grpc.NewServer(opts...)
	pb.RegisterManagerServiceServer(grpcServer, srv)

	// gRPC Health Check
	healthServer := health.NewServer()
	healthpb.RegisterHealthServer(grpcServer, healthServer)
	healthServer.SetServingStatus("titan.ManagerService", healthpb.HealthCheckResponse_SERVING)

	reflection.Register(grpcServer)

	// Start background services
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	reaper := manager.NewReaper(srv)
	go reaper.Run(ctx)

	// Start Web Dashboard
	dash := dashboard.New(srv, *dashPort)
	go dash.Start()
	log.Info("Web Dashboard at http://localhost:%d", *dashPort)

	// Graceful shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-quit
		log.Info("Received shutdown signal. Draining...")
		cancel()
		healthServer.SetServingStatus("titan.ManagerService", healthpb.HealthCheckResponse_NOT_SERVING)
		dash.Stop()
		grpcServer.GracefulStop()
	}()

	log.Info("Titan Manager listening on %s", addr)
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatal("Server error: %v", err)
	}
	log.Info("Manager stopped.")
}

func loggingInterceptor(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
	start := time.Now()
	resp, err := handler(ctx, req)
	d := time.Since(start)
	if err != nil {
		log.Error("[gRPC] ✗ %s (%s): %v", info.FullMethod, d, err)
	} else {
		log.Debug("[gRPC] ✓ %s (%s)", info.FullMethod, d)
	}
	return resp, err
}

func authInterceptor(validToken string) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		// Skip auth for health/reflection
		if len(info.FullMethod) > 5 {
			for _, prefix := range []string{"/grpc.health.", "/grpc.reflection."} {
				if len(info.FullMethod) >= len(prefix) && info.FullMethod[:len(prefix)] == prefix {
					return handler(ctx, req)
				}
			}
		}

		md, ok := gmd.FromIncomingContext(ctx)
		if !ok {
			return nil, status.Error(codes.Unauthenticated, "missing metadata")
		}
		tokens := md.Get("authorization")
		if len(tokens) == 0 || tokens[0] != "Bearer "+validToken {
			return nil, status.Error(codes.Unauthenticated, "invalid or missing token")
		}
		return handler(ctx, req)
	}
}
