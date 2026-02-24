package dashboard

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/adithyanca/titan/internal/logger"
	pb "github.com/adithyanca/titan/proto"
)

var log = logger.New("Dashboard")

// StatusProvider is the interface the dashboard needs from the Manager server.
type StatusProvider interface {
	ClusterStatus(context.Context, *pb.ClusterStatusRequest) (*pb.ClusterStatusResponse, error)
	ListTasks(context.Context, *pb.ListTasksRequest) (*pb.ListTasksResponse, error)
}

// Dashboard serves a real-time web UI for cluster monitoring.
type Dashboard struct {
	provider StatusProvider
	port     int
	server   *http.Server
}

// New creates a new Dashboard.
func New(provider StatusProvider, port int) *Dashboard {
	return &Dashboard{provider: provider, port: port}
}

// Start begins serving the dashboard. Non-blocking (call from goroutine).
func (d *Dashboard) Start() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", d.handleIndex)
	mux.HandleFunc("/api/status", d.handleAPIStatus)
	mux.HandleFunc("/api/tasks", d.handleAPITasks)

	d.server = &http.Server{
		Addr:    fmt.Sprintf(":%d", d.port),
		Handler: mux,
	}

	log.Info("Dashboard listening on :%d", d.port)
	if err := d.server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Error("Dashboard error: %v", err)
	}
}

// Stop gracefully shuts down the dashboard.
func (d *Dashboard) Stop() {
	if d.server != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		d.server.Shutdown(ctx)
	}
}

func (d *Dashboard) handleAPIStatus(w http.ResponseWriter, r *http.Request) {
	resp, err := d.provider.ClusterStatus(r.Context(), &pb.ClusterStatusRequest{})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func (d *Dashboard) handleAPITasks(w http.ResponseWriter, r *http.Request) {
	resp, err := d.provider.ListTasks(r.Context(), &pb.ListTasksRequest{})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func (d *Dashboard) handleIndex(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, dashboardHTML)
}

const dashboardHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Titan ⚡ Dashboard</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
    background: #0a0a0f;
    color: #e0e0e0;
    min-height: 100vh;
  }
  header {
    background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
    padding: 24px 40px;
    border-bottom: 1px solid rgba(255,255,255,0.06);
  }
  header h1 {
    font-size: 28px;
    font-weight: 700;
    background: linear-gradient(90deg, #00d2ff, #7b68ee);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
  }
  header p { color: #888; font-size: 14px; margin-top: 4px; }
  .container { max-width: 1200px; margin: 0 auto; padding: 32px 24px; }

  .stats-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 16px;
    margin-bottom: 32px;
  }
  .stat-card {
    background: rgba(255,255,255,0.04);
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 12px;
    padding: 20px;
    text-align: center;
    transition: all 0.3s ease;
  }
  .stat-card:hover {
    background: rgba(255,255,255,0.07);
    border-color: rgba(123,104,238,0.3);
    transform: translateY(-2px);
  }
  .stat-card .value {
    font-size: 36px;
    font-weight: 700;
    margin-bottom: 4px;
  }
  .stat-card .label { color: #888; font-size: 13px; text-transform: uppercase; letter-spacing: 1px; }
  .pending .value { color: #f0ad4e; }
  .running .value { color: #5bc0de; }
  .completed .value { color: #5cb85c; }
  .failed .value { color: #d9534f; }

  .section-title {
    font-size: 18px;
    font-weight: 600;
    margin-bottom: 16px;
    color: #bbb;
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .section-title::before {
    content: '';
    width: 4px;
    height: 20px;
    background: linear-gradient(180deg, #00d2ff, #7b68ee);
    border-radius: 2px;
  }

  table {
    width: 100%;
    border-collapse: collapse;
    background: rgba(255,255,255,0.02);
    border-radius: 12px;
    overflow: hidden;
    border: 1px solid rgba(255,255,255,0.06);
    margin-bottom: 32px;
  }
  th {
    background: rgba(255,255,255,0.04);
    padding: 12px 16px;
    text-align: left;
    font-size: 12px;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: #888;
    font-weight: 600;
  }
  td { padding: 12px 16px; border-top: 1px solid rgba(255,255,255,0.04); font-size: 14px; }
  tr:hover td { background: rgba(255,255,255,0.03); }

  .badge {
    display: inline-block;
    padding: 3px 10px;
    border-radius: 20px;
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }
  .badge-idle { background: rgba(92,192,222,0.15); color: #5bc0de; }
  .badge-busy { background: rgba(240,173,78,0.15); color: #f0ad4e; }
  .badge-dead { background: rgba(217,83,79,0.15); color: #d9534f; }
  .badge-pending { background: rgba(240,173,78,0.15); color: #f0ad4e; }
  .badge-running { background: rgba(91,192,222,0.15); color: #5bc0de; }
  .badge-completed { background: rgba(92,184,92,0.15); color: #5cb85c; }
  .badge-failed { background: rgba(217,83,79,0.15); color: #d9534f; }

  .pulse-dot {
    width: 8px; height: 8px;
    background: #5cb85c;
    border-radius: 50%;
    display: inline-block;
    margin-right: 8px;
    animation: pulse 2s infinite;
  }
  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.3; }
  }
  .refresh-info { color: #555; font-size: 12px; text-align: right; margin-bottom: 12px; }
  .mono { font-family: 'SF Mono', 'Fira Code', monospace; font-size: 13px; }
  @media (max-width: 768px) { .stats-grid { grid-template-columns: repeat(2, 1fr); } }
</style>
</head>
<body>
<header>
  <h1>⚡ Titan Dashboard</h1>
  <p>Distributed Task Orchestrator — Real-time Cluster Monitor</p>
</header>
<div class="container">
  <div class="refresh-info"><span class="pulse-dot"></span>Auto-refreshes every 3 seconds</div>

  <div class="stats-grid">
    <div class="stat-card pending"><div class="value" id="pending">-</div><div class="label">Pending</div></div>
    <div class="stat-card running"><div class="value" id="running">-</div><div class="label">Running</div></div>
    <div class="stat-card completed"><div class="value" id="completed">-</div><div class="label">Completed</div></div>
    <div class="stat-card failed"><div class="value" id="failed">-</div><div class="label">Failed</div></div>
  </div>

  <div class="section-title">Workers</div>
  <table>
    <thead><tr><th>Worker ID</th><th>Status</th><th>Current Task</th><th>Last Seen</th></tr></thead>
    <tbody id="workers"><tr><td colspan="4" style="text-align:center;color:#555">Loading...</td></tr></tbody>
  </table>

  <div class="section-title">Tasks</div>
  <table>
    <thead><tr><th>Task ID</th><th>Status</th><th>Retries</th><th>Worker</th><th>Command</th></tr></thead>
    <tbody id="tasks"><tr><td colspan="5" style="text-align:center;color:#555">Loading...</td></tr></tbody>
  </table>
</div>

<script>
const statusMap = {0:'UNKNOWN',1:'IDLE',2:'BUSY',3:'DEAD'};
const taskStatusMap = {0:'UNKNOWN',1:'PENDING',2:'RUNNING',3:'COMPLETED',4:'FAILED'};
const badgeClass = s => 'badge badge-' + s.toLowerCase();

async function refresh() {
  try {
    const [statusRes, tasksRes] = await Promise.all([
      fetch('/api/status').then(r => r.json()),
      fetch('/api/tasks').then(r => r.json())
    ]);

    document.getElementById('pending').textContent = statusRes.pendingTasks || 0;
    document.getElementById('running').textContent = statusRes.runningTasks || 0;
    document.getElementById('completed').textContent = statusRes.completedTasks || 0;
    document.getElementById('failed').textContent = statusRes.failedTasks || 0;

    const wt = document.getElementById('workers');
    if (statusRes.workers && statusRes.workers.length > 0) {
      wt.innerHTML = statusRes.workers.map(w => {
        const st = statusMap[w.status] || 'UNKNOWN';
        const seen = w.lastSeen ? new Date(w.lastSeen * 1000).toLocaleTimeString() : '-';
        return '<tr><td class="mono">' + w.workerId + '</td><td><span class="' + badgeClass(st) + '">' + st + '</span></td><td class="mono">' + (w.currentTask || '—') + '</td><td>' + seen + '</td></tr>';
      }).join('');
    } else {
      wt.innerHTML = '<tr><td colspan="4" style="text-align:center;color:#555">No workers registered</td></tr>';
    }

    const tt = document.getElementById('tasks');
    if (tasksRes.tasks && tasksRes.tasks.length > 0) {
      tt.innerHTML = tasksRes.tasks.map(t => {
        const st = taskStatusMap[t.status] || 'UNKNOWN';
        const cmd = t.command && t.command.length > 50 ? t.command.slice(0,47) + '...' : (t.command || '');
        return '<tr><td class="mono">' + (t.id||'').slice(0,8) + '...</td><td><span class="' + badgeClass(st) + '">' + st + '</span></td><td>' + (t.retryCount||0) + '/' + (t.maxRetries||3) + '</td><td class="mono">' + (t.workerId || '—') + '</td><td class="mono">' + cmd + '</td></tr>';
      }).join('');
    } else {
      tt.innerHTML = '<tr><td colspan="5" style="text-align:center;color:#555">No tasks submitted</td></tr>';
    }
  } catch(e) { console.error('refresh error:', e); }
}

refresh();
setInterval(refresh, 3000);
</script>
</body>
</html>`
