package main

import (
	"context"
	"flag"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/adithyanca/titan/internal/logger"
	"github.com/adithyanca/titan/internal/tlsconfig"
	"github.com/adithyanca/titan/internal/worker"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

var log = logger.New("Worker")

func main() {
	managerAddr := flag.String("manager", "localhost:50051", "Manager gRPC address")
	workerID := flag.String("id", "", "Unique worker ID (auto-generated if empty)")

	// TLS flags
	useTLS := flag.Bool("tls", false, "Enable mTLS")
	tlsCert := flag.String("tls-cert", "certs/client.pem", "TLS certificate file")
	tlsKey := flag.String("tls-key", "certs/client-key.pem", "TLS private key file")
	tlsCA := flag.String("tls-ca", "certs/ca.pem", "TLS CA certificate file")

	flag.Parse()

	if *workerID == "" {
		hostname, _ := os.Hostname()
		*workerID = hostname + "-" + randomSuffix()
	}

	log.Info("Starting with id=%s  manager=%s  tls=%v", *workerID, *managerAddr, *useTLS)

	// Build dial options
	var dialOpts []grpc.DialOption
	if *useTLS {
		creds, err := tlsconfig.ClientCredentials(*tlsCert, *tlsKey, *tlsCA)
		if err != nil {
			log.Fatal("Failed to load TLS credentials: %v", err)
		}
		dialOpts = append(dialOpts, grpc.WithTransportCredentials(creds))
		log.Info("mTLS enabled (cert=%s)", *tlsCert)
	} else {
		dialOpts = append(dialOpts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-quit
		log.Info("Shutdown signal received.")
		cancel()
	}()

	client := worker.NewClientWithOpts(*workerID, *managerAddr, dialOpts)
	if err := client.Run(ctx); err != nil {
		log.Fatal("Fatal error: %v", err)
	}
}

func randomSuffix() string {
	return time.Now().Format("150405")
}
