#!/usr/bin/env python3
"""
Agent-Based OpenShift Installation Monitor
GUI to monitor cluster and host status via assisted-installer API
"""

import tkinter as tk
from tkinter import ttk
import requests
import json
import threading
import time
import os
import subprocess
import yaml

# Configuration
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(SCRIPT_DIR, "gw", ".openshift_install_state.json")
AGENT_CONFIG_FILE = os.path.join(SCRIPT_DIR, "agent-config.yaml")
API_URL = "http://192.168.1.201:8090/api/assisted-install/v2"
REFRESH_INTERVAL = 5000  # ms
EVENT_POLL_INTERVAL = 2  # seconds - faster polling for events

LOG_FILE = "/tmp/monitor-debug.log"
EVENT_FILE = "/tmp/monitor-events.log"
DEBUG_CHECK_INTERVAL = 30000  # ms - debug checks every 30 seconds
SSH_OPTS = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5"]
GATHERDEBUG_SCRIPT = os.path.join(SCRIPT_DIR, "gatherdebug.sh")

# Single SSH command to collect all debug info from a node
SSH_CHECK_CMD = '; '.join([
    'echo "===KUBELET==="',
    'systemctl is-active kubelet 2>/dev/null || echo inactive',
    'echo "===CRIO==="',
    'systemctl is-active crio 2>/dev/null || echo inactive',
    'echo "===ISSUES==="',
    'sudo journalctl --no-pager -n 1000 -q 2>&1 | grep -iE '
    '"x509|certificate.*unknown|crypto.*verification|ErrImagePull|ImagePullBackOff'
    '|manifest unknown|OOMKill|No space left" | tail -10',
    'echo "===MC==="',
    "python3 -c \"import json; d=json.load(open('/etc/machine-config-daemon/currentconfig'));"
    " print(d['metadata']['name'])\" 2>/dev/null || echo not-found",
    'echo "===DISK==="',
    'df -h / /var 2>/dev/null | tail -2',
    'echo "===MEM==="',
    'free -m 2>/dev/null | grep Mem',
    'echo "===CONTAINERS==="',
    'sudo crictl ps -a 2>/dev/null | grep -v Running | grep -v CONTAINER | tail -5',
    'echo "===END==="',
])

def log(msg):
    """Debug logging to file"""
    with open(LOG_FILE, "a") as f:
        f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
        f.flush()

def log_event(msg, severity="info"):
    """Log event to event file and print to console"""
    timestamp = time.strftime('%H:%M:%S')
    prefix = {"error": "ERR", "warning": "WRN", "info": "   ", "critical": "CRT"}.get(severity, "   ")
    line = f"[{timestamp}] {prefix} {msg}"
    print(line, flush=True)
    with open(EVENT_FILE, "a") as f:
        f.write(line + "\n")
        f.flush()

def get_auth_token():
    """Read auth token from state file"""
    try:
        with open(STATE_FILE, 'r') as f:
            state = json.load(f)
            token = state.get("*gencrypto.AuthConfig", {}).get("UserAuthToken", "")
            return token
    except Exception as e:
        log(f"Token error: {e}")
        return ""


class AgentMonitor:
    def __init__(self, root):
        self.root = root
        self.root.title("OpenShift Agent Installation Monitor")
        self.root.geometry("900x700")

        self.cluster_id = None
        self.infra_env_id = None
        self.mode = "api"  # "api" or "oc"
        self.api_fail_count = 0
        self.api_success_count = 0
        self.switched_to_install = False
        self.selected_host_id = None
        self.seen_event_ids = set()
        self.event_streamer_running = False

        # Load hostname mappings from agent-config.yaml
        self.hostname_by_mac = {}
        self.hostname_by_role = {"master": [], "worker": []}
        self._load_agent_config()

        # Debug state
        self.node_ips = {}
        self._load_node_ips()
        self.debug_findings = {}
        self.debug_checking = False
        self.last_debug_check = None

        # Clear logs and write startup info
        with open(LOG_FILE, "w") as f:
            f.write(f"Monitor started at {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        with open(EVENT_FILE, "w") as f:
            f.write(f"=== Events started at {time.strftime('%Y-%m-%d %H:%M:%S')} ===\n")
        log(f"STATE_FILE: {STATE_FILE}")
        log(f"API_URL: {API_URL}")
        log(f"State file exists: {os.path.exists(STATE_FILE)}")
        token = get_auth_token()
        log(f"Token available: {bool(token)}")

        self.setup_ui()
        # Delay first refresh until mainloop starts
        self.root.after(100, self.refresh)
        # Start event streamer
        self.start_event_streamer()
        # Start debug checker (first check after 5s, then every 30s)
        self.root.after(5000, self._schedule_debug_check)

    def setup_ui(self):
        # Cluster status frame
        cluster_frame = ttk.LabelFrame(self.root, text="Cluster Status", padding=10)
        cluster_frame.pack(fill=tk.X, padx=10, pady=5)

        status_row = ttk.Frame(cluster_frame)
        status_row.pack(anchor=tk.W)
        ttk.Label(status_row, text="Status:", font=("Helvetica", 10)).pack(side=tk.LEFT)
        self.cluster_status = ttk.Label(status_row, text="Loading...", font=("Helvetica", 24, "bold"))
        self.cluster_status.pack(side=tk.LEFT, padx=(5, 0))

        self.cluster_info = ttk.Label(cluster_frame, text="", wraplength=850)
        self.cluster_info.pack(anchor=tk.W)

        # Progress bar
        progress_frame = ttk.Frame(cluster_frame)
        progress_frame.pack(fill=tk.X, pady=(10, 0))
        self.progress_bar = ttk.Progressbar(progress_frame, length=400, mode='determinate', maximum=100)
        self.progress_bar.pack(side=tk.LEFT)
        self.progress_label = ttk.Label(progress_frame, text="0%", font=("Helvetica", 12))
        self.progress_label.pack(side=tk.LEFT, padx=(10, 0))

        # Hosts frame
        hosts_frame = ttk.LabelFrame(self.root, text="Hosts", padding=10)
        hosts_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=5)

        # Treeview for hosts
        columns = ("hostname", "role", "status", "disk", "progress")
        self.hosts_tree = ttk.Treeview(hosts_frame, columns=columns, show="headings", height=8)

        self.hosts_tree.heading("hostname", text="Hostname")
        self.hosts_tree.heading("role", text="Role")
        self.hosts_tree.heading("status", text="Status")
        self.hosts_tree.heading("disk", text="Disk")
        self.hosts_tree.heading("progress", text="Progress")

        self.hosts_tree.column("hostname", width=150)
        self.hosts_tree.column("role", width=80)
        self.hosts_tree.column("status", width=100)
        self.hosts_tree.column("disk", width=100)
        self.hosts_tree.column("progress", width=200)

        self.hosts_tree.pack(fill=tk.BOTH, expand=True)
        self.hosts_tree.bind("<<TreeviewSelect>>", self.on_host_select)

        # Tabbed details section
        self.notebook = ttk.Notebook(self.root)
        self.notebook.pack(fill=tk.BOTH, expand=True, padx=10, pady=5)

        # Summary tab (all failing validations)
        summary_frame = ttk.Frame(self.notebook, padding=10)
        self.notebook.add(summary_frame, text="Summary")

        self.summary_text = tk.Text(summary_frame, height=15, wrap=tk.WORD)
        summary_scrollbar = ttk.Scrollbar(summary_frame, orient=tk.VERTICAL, command=self.summary_text.yview)
        self.summary_text.configure(yscrollcommand=summary_scrollbar.set)
        self.summary_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        summary_scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        # Configure tags for summary
        self.summary_text.tag_configure("host", foreground="#4a6fa5", font=("Helvetica", 10, "bold"))
        self.summary_text.tag_configure("failure", foreground="#a05050")
        self.summary_text.tag_configure("error", foreground="#8b7355")
        self.summary_text.tag_configure("success", foreground="#2d7d2d")

        # Validation tab (selected host details)
        validation_frame = ttk.Frame(self.notebook, padding=10)
        self.notebook.add(validation_frame, text="Validation")

        self.details_text = tk.Text(validation_frame, height=15, wrap=tk.WORD)
        scrollbar = ttk.Scrollbar(validation_frame, orient=tk.VERTICAL, command=self.details_text.yview)
        self.details_text.configure(yscrollcommand=scrollbar.set)
        self.details_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        # Configure tags for coloring
        self.details_text.tag_configure("success", foreground="#2d7d2d")
        self.details_text.tag_configure("failure", foreground="#a05050")
        self.details_text.tag_configure("error", foreground="#8b7355")
        self.details_text.tag_configure("pending", foreground="#777777")

        # Installation tab
        install_frame = ttk.Frame(self.notebook, padding=10)
        self.notebook.add(install_frame, text="Installation")

        self.install_text = tk.Text(install_frame, height=15, wrap=tk.WORD)
        install_scrollbar = ttk.Scrollbar(install_frame, orient=tk.VERTICAL, command=self.install_text.yview)
        self.install_text.configure(yscrollcommand=install_scrollbar.set)
        self.install_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        install_scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        # Configure tags for install log
        self.install_text.tag_configure("stage", foreground="#4a6fa5", font=("Helvetica", 10, "bold"))
        self.install_text.tag_configure("info", foreground="#555555")
        self.install_text.tag_configure("done", foreground="#2d7d2d")
        self.install_text.tag_configure("error", foreground="#a05050")

        self.switched_to_install = False

        # Debug tab
        debug_frame = ttk.Frame(self.notebook, padding=10)
        self.notebook.add(debug_frame, text="Debug")

        debug_btn_frame = ttk.Frame(debug_frame)
        debug_btn_frame.pack(fill=tk.X, pady=(0, 5))

        ttk.Button(debug_btn_frame, text="Check Now",
                   command=self.run_debug_check).pack(side=tk.LEFT, padx=2)
        ttk.Button(debug_btn_frame, text="Gather Debug",
                   command=self.run_gather_debug).pack(side=tk.LEFT, padx=2)
        self.debug_auto_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(debug_btn_frame, text="Auto-check",
                        variable=self.debug_auto_var).pack(side=tk.LEFT, padx=10)
        self.debug_status_label = ttk.Label(debug_btn_frame, text="")
        self.debug_status_label.pack(side=tk.RIGHT, padx=5)

        self.debug_text = tk.Text(debug_frame, height=15, wrap=tk.WORD)
        debug_scrollbar = ttk.Scrollbar(debug_frame, orient=tk.VERTICAL,
                                        command=self.debug_text.yview)
        self.debug_text.configure(yscrollcommand=debug_scrollbar.set)
        self.debug_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        debug_scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        self.debug_text.tag_configure("header", foreground="#4a6fa5",
                                      font=("Helvetica", 10, "bold"))
        self.debug_text.tag_configure("ok", foreground="#2d7d2d")
        self.debug_text.tag_configure("warning", foreground="#8b7355")
        self.debug_text.tag_configure("error", foreground="#a05050")
        self.debug_text.tag_configure("detail", foreground="#777777")
        self.debug_text.tag_configure("info", foreground="#555555")

        # Control buttons
        btn_frame = ttk.Frame(self.root)
        btn_frame.pack(fill=tk.X, padx=10, pady=5)

        ttk.Button(btn_frame, text="Refresh", command=self.refresh).pack(side=tk.LEFT, padx=5)
        ttk.Button(btn_frame, text="Quit", command=self.root.quit).pack(side=tk.RIGHT, padx=5)

        self.status_label = ttk.Label(btn_frame, text="")
        self.status_label.pack(side=tk.LEFT, padx=20)

    def api_request(self, endpoint):
        try:
            token = get_auth_token()
            if not token:
                log(f"API {endpoint}: no token")
                return "no_token"
            headers = {"Authorization": token}
            response = requests.get(f"{API_URL}{endpoint}", headers=headers, timeout=5, verify=False)
            log(f"API {endpoint}: {response.status_code}")
            if response.status_code == 200:
                return response.json()
            return None
        except Exception as e:
            log(f"API {endpoint}: error {e}")
            return None

    def get_cluster(self):
        clusters = self.api_request("/clusters")
        if clusters == "no_token":
            return "no_token"
        if clusters and isinstance(clusters, list) and len(clusters) > 0:
            return clusters[0]
        return None

    def get_hosts(self, cluster_id):
        # Try infra-env hosts first (has more complete data including requested_hostname)
        if self.infra_env_id:
            hosts = self.api_request(f"/infra-envs/{self.infra_env_id}/hosts") or []
            if hosts and hosts[0].get("requested_hostname"):
                log(f"Using infra-env hosts (has requested_hostname)")
                return hosts

        # Fall back to cluster hosts
        hosts = self.api_request(f"/clusters/{cluster_id}/hosts") or []
        if hosts:
            h = hosts[0]
            log(f"Host keys: {list(h.keys())}")
            log(f"requested_hostname: {h.get('requested_hostname')}")
            inv = h.get('inventory', '')
            if inv:
                try:
                    inv_data = json.loads(inv)
                    log(f"inventory.hostname: {inv_data.get('hostname')}")
                except:
                    log(f"inventory parse failed")
        return hosts

    def get_events(self, cluster_id):
        return self.api_request(f"/events?cluster_id={cluster_id}") or []

    def kube_api_reachable(self):
        """Check if kube API port is reachable (fast TCP check)"""
        import socket
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(1)
            result = sock.connect_ex(('api.gw.lo', 6443))
            sock.close()
            return result == 0
        except:
            return False

    def get_oc_nodes(self):
        """Get nodes via oc command"""
        try:
            result = subprocess.run(
                ["oc", "get", "nodes", "-o", "json"],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                return json.loads(result.stdout).get("items", [])
        except:
            pass
        return []

    def get_oc_operators(self):
        """Get cluster operators via oc command"""
        try:
            result = subprocess.run(
                ["oc", "get", "co", "-o", "json"],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                return json.loads(result.stdout).get("items", [])
        except:
            pass
        return []

    def refresh(self):
        log(f"Refresh called, mode={self.mode}")
        def do_refresh():
            if self.mode == "api":
                cluster = self.get_cluster()

                if cluster == "no_token":
                    self.root.after(0, lambda: self.cluster_status.config(
                        text="NO TOKEN",
                        foreground="#8b7355"
                    ))
                    self.root.after(0, lambda: self.status_label.config(
                        text="Waiting for state file..."
                    ))
                elif cluster:
                    self.api_fail_count = 0
                    self.api_success_count += 1
                    self.cluster_id = cluster.get("id")
                    self.infra_env_id = cluster.get("infra_env_id")
                    status = cluster.get("status", "unknown")
                    status_info = cluster.get("status_info", "")
                    progress = cluster.get("progress", {})
                    total_pct = progress.get("total_percentage", 0)

                    # Update cluster status with percentage
                    if total_pct > 0:
                        status_text = f"{status.upper()} ({total_pct}%)"
                    else:
                        status_text = status.upper()

                    log(f"Updating GUI: status={status_text}")
                    self.root.after(0, lambda t=status_text, s=status: self.cluster_status.config(
                        text=t,
                        foreground=self.status_color(s)
                    ))
                    self.root.after(0, lambda si=status_info: self.cluster_info.config(text=si))

                    # Update progress bar
                    self.root.after(0, lambda p=total_pct: self.progress_bar.config(value=p))
                    self.root.after(0, lambda p=total_pct: self.progress_label.config(text=f"{p}%"))

                    # Get hosts
                    hosts = self.get_hosts(self.cluster_id)
                    self.root.after(0, lambda h=hosts: self.update_hosts(h))

                    # Switch to install tab and update install log when installing
                    if status in ("preparing-for-installation", "installing", "finalizing") and not self.switched_to_install:
                        self.root.after(0, lambda: self.notebook.select(2))  # Installation tab is index 2
                        self.switched_to_install = True

                    if status in ("preparing-for-installation", "installing", "finalizing", "installed"):
                        events = self.get_events(self.cluster_id)
                        self.root.after(0, lambda e=events: self.update_install_log(e))

                    # Switch to oc mode when kube API is reachable AND all nodes have joined
                    if self.kube_api_reachable():
                        nodes = self.get_oc_nodes()
                        expected_nodes = len(self.hostname_by_mac)  # From agent-config
                        if len(nodes) >= expected_nodes and expected_nodes > 0:
                            self.mode = "oc"
                            log(f"Switching to oc mode ({len(nodes)}/{expected_nodes} nodes joined)")

                    self.root.after(0, lambda: self.status_label.config(
                        text=f"Last update: {time.strftime('%H:%M:%S')}"
                    ))
                    self.root.after(0, lambda: self.root.update_idletasks())
                else:
                    self.api_fail_count += 1
                    # Only switch to oc mode if API was working before (bootstrap complete)
                    # api_success_count > 0 means we connected at least once
                    if self.api_fail_count >= 3 and self.api_success_count > 5:
                        self.mode = "oc"
                        log("Switching to oc mode (API was up, now down = bootstrap complete)")
                        self.root.after(0, lambda: self.cluster_info.config(
                            text="Switched to cluster monitoring (bootstrap complete)"
                        ))
                    else:
                        self.root.after(0, lambda: self.cluster_status.config(
                            text="WAITING...",
                            foreground="#8b7355"
                        ))
                        self.root.after(0, lambda: self.status_label.config(
                            text=f"Waiting on API... ({self.api_fail_count})"
                        ))

            if self.mode == "oc":
                self.refresh_oc_mode()

        # Run in background thread with error handling
        def safe_refresh():
            try:
                do_refresh()
            except Exception as e:
                print(f"Refresh error: {e}")
        threading.Thread(target=safe_refresh, daemon=True).start()

        # Schedule next refresh
        self.root.after(REFRESH_INTERVAL, self.refresh)

    def refresh_oc_mode(self):
        """Refresh using oc commands instead of API"""
        nodes = self.get_oc_nodes()
        operators = self.get_oc_operators()

        if not nodes:
            self.root.after(0, lambda: self.cluster_status.config(
                text="CONNECTING...",
                foreground="#8b7355"
            ))
            return

        # Count ready nodes
        ready_nodes = sum(1 for n in nodes if any(
            c.get("type") == "Ready" and c.get("status") == "True"
            for c in n.get("status", {}).get("conditions", [])
        ))
        total_nodes = len(nodes)

        # Count available operators
        available_ops = sum(1 for o in operators if any(
            c.get("type") == "Available" and c.get("status") == "True"
            for c in o.get("status", {}).get("conditions", [])
        ))
        total_ops = len(operators)

        # Calculate progress (nodes=30%, operators=70%)
        node_pct = (ready_nodes / total_nodes * 30) if total_nodes > 0 else 0
        op_pct = (available_ops / total_ops * 70) if total_ops > 0 else 0
        total_pct = int(node_pct + op_pct)

        if total_pct >= 100:
            status_text = "INSTALLED"
            status = "installed"
        else:
            status_text = f"FINALIZING ({total_pct}%)"
            status = "installing"

        self.root.after(0, lambda t=status_text, s=status: self.cluster_status.config(
            text=t,
            foreground=self.status_color(s)
        ))
        self.root.after(0, lambda: self.cluster_info.config(
            text=f"Nodes: {ready_nodes}/{total_nodes} Ready | Operators: {available_ops}/{total_ops} Available"
        ))
        self.root.after(0, lambda p=total_pct: self.progress_bar.config(value=p))
        self.root.after(0, lambda p=total_pct: self.progress_label.config(text=f"{total_pct}%"))

        # Update hosts table with nodes and operator rollout info
        self.root.after(0, lambda n=nodes, o=operators: self.update_nodes_table(n, o))

        # Update summary with nodes and problem operators
        self.root.after(0, lambda n=nodes, o=operators: self.update_operator_summary(o, n))

        # Update install log with operators
        self.root.after(0, lambda o=operators: self.update_operators_log(o))

        self.root.after(0, lambda: self.status_label.config(
            text=f"Last update: {time.strftime('%H:%M:%S')} (oc)"
        ))

    def _load_agent_config(self):
        """Load hostname mappings from agent-config.yaml"""
        try:
            if os.path.exists(AGENT_CONFIG_FILE):
                with open(AGENT_CONFIG_FILE, 'r') as f:
                    config = yaml.safe_load(f)
                    for host in config.get("hosts", []):
                        hostname = host.get("hostname", "")
                        role = host.get("role", "worker")
                        # Map by MAC address
                        for iface in host.get("interfaces", []):
                            mac = iface.get("macAddress", "").lower()
                            if mac and hostname:
                                self.hostname_by_mac[mac] = hostname
                        # Map by role (ordered list)
                        if hostname:
                            if role == "master":
                                self.hostname_by_role["master"].append(hostname)
                            else:
                                self.hostname_by_role["worker"].append(hostname)
                log(f"Loaded {len(self.hostname_by_mac)} hostname mappings from agent-config.yaml")
                log(f"Masters: {self.hostname_by_role['master']}")
                log(f"Workers: {self.hostname_by_role['worker']}")
        except Exception as e:
            log(f"Failed to load agent-config.yaml: {e}")

    def get_hostname(self, host):
        """Get hostname from host data, falling back to agent-config.yaml mappings"""
        hostname = host.get("requested_hostname") or ""
        source = "requested_hostname" if hostname else ""

        # Try inventory
        if not hostname:
            try:
                inventory = json.loads(host.get("inventory", "{}"))
                hostname = inventory.get("hostname") or ""
                if hostname:
                    source = "inventory.hostname"
                # Try MAC address lookup from inventory interfaces
                if not hostname:
                    ifaces = inventory.get("interfaces", [])
                    for iface in ifaces:
                        mac = iface.get("mac_address", "").lower()
                        if mac in self.hostname_by_mac:
                            hostname = self.hostname_by_mac[mac]
                            source = "agent-config (MAC)"
                            break
                        # Fallback to IP
                        if not hostname:
                            addrs = iface.get("ipv4_addresses", [])
                            if addrs:
                                hostname = addrs[0].split("/")[0]
                                source = "ipv4_address"
                                break
            except Exception as e:
                log(f"get_hostname inventory parse error: {e}")

        # Fallback: use role-based lookup from agent-config.yaml
        if not hostname or hostname == "unknown":
            role = host.get("role") or host.get("suggested_role") or ""
            if role == "master" and self.hostname_by_role["master"]:
                # Use bootstrap flag or index to pick hostname
                bootstrap = host.get("bootstrap", False)
                if bootstrap:
                    hostname = self.hostname_by_role["master"][0]
                    source = "agent-config (bootstrap)"
            # If still no match, show role with partial ID
            if not hostname:
                host_id = host.get("id", "")[:8]
                if role:
                    hostname = f"{role}-{host_id}"
                    source = "role+id"

        result = hostname or "unknown"
        log(f"get_hostname: {result} (from {source or 'none'})")
        return result

    def status_color(self, status):
        colors = {
            "ready": "#2d7d2d",
            "installed": "#2d7d2d",
            "done": "#2d7d2d",
            "installing": "#4a6fa5",
            "installing-in-progress": "#4a6fa5",
            "preparing-for-installation": "#4a6fa5",
            "preparing-successful": "#4a6fa5",
            "pending-for-input": "#8b7355",
            "insufficient": "#8b7355",
            "rebooting": "#6b5b7a",
            "error": "#a05050",
            "known": "#2d7d2d",
        }
        return colors.get(status, "#555555")

    def update_hosts(self, hosts):
        # Clear existing items
        for item in self.hosts_tree.get_children():
            self.hosts_tree.delete(item)

        # Store hosts data for detail view
        self.hosts_data = {}

        # Sort by role (master first), then by hostname
        def sort_key(h):
            role = h.get("role", "worker")
            hostname = h.get("requested_hostname") or ""
            role_order = 0 if role == "master" else 1
            return (role_order, hostname)

        first_failing_host_id = None
        for host in sorted(hosts, key=sort_key):
            host_id = host.get("id")
            hostname = self.get_hostname(host)
            role = host.get("role", "auto-assign")
            status = host.get("status", "unknown")
            status_info = host.get("status_info", "")

            # Track first host with failing validation
            if not first_failing_host_id:
                try:
                    validations = json.loads(host.get("validations_info", "{}"))
                    for category, checks in validations.items():
                        for check in checks:
                            if check.get("status") in ("failure", "error"):
                                first_failing_host_id = host_id
                                break
                        if first_failing_host_id:
                            break
                except:
                    pass

            # Get disk info from inventory
            disk_info = "N/A"
            try:
                inventory = json.loads(host.get("inventory", "{}"))
                disks = inventory.get("disks", [])
                for d in disks:
                    if d.get("name") == "sda":
                        size_gb = d.get("size_bytes", 0) // (1024**3)
                        eligible = d.get("installation_eligibility", {}).get("eligible")
                        disk_info = f"{size_gb}GB {'✓' if eligible else '✗'}"
            except:
                pass

            # Show progress percentage and stage
            progress = host.get("progress", {})
            pct = progress.get("installation_percentage", 0)
            stage = progress.get("current_stage", "")
            if pct > 0:
                progress_text = f"{pct}% - {stage}"
            elif stage:
                progress_text = stage
            else:
                progress_text = status_info[:40] + "..." if len(status_info) > 40 else status_info

            self.hosts_tree.insert("", tk.END, iid=host_id, values=(
                hostname, role, status, disk_info, progress_text
            ))

            # Color by status
            self.hosts_tree.tag_configure(status, foreground=self.status_color(status))
            self.hosts_tree.item(host_id, tags=(status,))

            # Store for details
            self.hosts_data[host_id] = host

        # Auto-select first host if none selected, or re-select previously selected
        children = self.hosts_tree.get_children()
        if children:
            if self.selected_host_id and self.selected_host_id in children:
                self.hosts_tree.selection_set(self.selected_host_id)
                self.show_host_details(self.selected_host_id)
            elif not self.selected_host_id:
                # Select first host by default
                self.selected_host_id = children[0]
                self.hosts_tree.selection_set(self.selected_host_id)
                self.show_host_details(self.selected_host_id)

        # Update summary tab with all failing validations
        self.update_summary(hosts)

    def update_summary(self, hosts):
        """Update summary tab with all failing validations across all hosts"""
        self.summary_text.delete("1.0", tk.END)

        has_failures = False
        for host in hosts:
            hostname = self.get_hostname(host)

            # Collect failures for this host
            host_failures = []
            try:
                validations = json.loads(host.get("validations_info", "{}"))
                for category, checks in validations.items():
                    for check in checks:
                        status = check.get("status", "")
                        if status in ("failure", "error"):
                            check_id = check.get("id", "")
                            msg = check.get("message", "")
                            host_failures.append((status, check_id, msg))
            except:
                pass

            # Display failures for this host
            if host_failures:
                has_failures = True
                self.summary_text.insert(tk.END, f"\n{hostname}\n", "host")
                for status, check_id, msg in host_failures:
                    tag = "failure" if status == "failure" else "error"
                    symbol = "✗" if status == "failure" else "!"
                    self.summary_text.insert(tk.END, f"  {symbol} {check_id}: {msg}\n", tag)

        if not has_failures:
            self.summary_text.insert(tk.END, "All validations passing\n", "success")

    def update_operator_summary(self, operators, nodes=None):
        """Update summary tab with nodes and problem operators"""
        self.summary_text.delete("1.0", tk.END)

        # Show node status first
        if nodes:
            self.summary_text.insert(tk.END, "Nodes\n", "host")
            for node in sorted(nodes, key=lambda n: n.get("metadata", {}).get("name", "")):
                name = node.get("metadata", {}).get("name", "unknown")
                labels = node.get("metadata", {}).get("labels", {})
                conditions = node.get("status", {}).get("conditions", [])
                ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions)

                role = "master" if "node-role.kubernetes.io/master" in labels or "node-role.kubernetes.io/control-plane" in labels else "worker"

                if ready:
                    self.summary_text.insert(tk.END, f"  ✓ {name} ({role}) Ready\n", "success")
                else:
                    self.summary_text.insert(tk.END, f"  ○ {name} ({role}) NotReady\n", "error")
            self.summary_text.insert(tk.END, "\n")

        # Show problem operators
        problem_ops = []
        for op in operators:
            name = op.get("metadata", {}).get("name", "unknown")
            conditions = op.get("status", {}).get("conditions", [])

            available = any(c.get("type") == "Available" and c.get("status") == "True" for c in conditions)
            progressing = any(c.get("type") == "Progressing" and c.get("status") == "True" for c in conditions)
            degraded = any(c.get("type") == "Degraded" and c.get("status") == "True" for c in conditions)

            # Get message
            msg = ""
            for c in conditions:
                if c.get("type") == "Progressing" and c.get("message"):
                    msg = c.get("message", "")
                    break
                if c.get("type") == "Degraded" and c.get("status") == "True" and c.get("message"):
                    msg = c.get("message", "")
                    break

            if degraded:
                problem_ops.append((name, "degraded", msg))
            elif not available:
                problem_ops.append((name, "unavailable", msg))
            elif progressing:
                problem_ops.append((name, "progressing", msg))

        if problem_ops:
            self.summary_text.insert(tk.END, f"Problem Operators ({len(problem_ops)})\n", "host")
            for name, status, msg in problem_ops:
                if status == "degraded":
                    self.summary_text.insert(tk.END, f"  ✗ {name} (degraded)\n", "failure")
                elif status == "unavailable":
                    self.summary_text.insert(tk.END, f"  ○ {name} (unavailable)\n", "error")
                else:
                    self.summary_text.insert(tk.END, f"  ● {name} (progressing)\n", "pending")
                if msg:
                    self.summary_text.insert(tk.END, f"      {msg[:100]}\n", "pending")
        else:
            self.summary_text.insert(tk.END, "All operators available\n", "success")

    def update_install_log(self, events):
        """Update installation event log"""
        self.install_text.delete("1.0", tk.END)

        # Show recent events (last 50)
        for event in events[-50:]:
            msg = event.get("message", "")
            severity = event.get("severity", "info")

            # Color based on content
            if "Done" in msg or "installed" in msg:
                tag = "done"
            elif "error" in msg.lower() or severity == "error":
                tag = "error"
            else:
                tag = "info"

            self.install_text.insert(tk.END, f"INFO {msg}\n", tag)

        # Auto-scroll to bottom
        self.install_text.see(tk.END)

    def update_nodes_table(self, nodes, operators=None):
        """Update hosts table with node info from oc"""
        for item in self.hosts_tree.get_children():
            self.hosts_tree.delete(item)

        self.hosts_data = {}

        # Build map of which operators are rolling out to which nodes
        node_rollouts = {}
        control_plane_ops = {"etcd", "kube-apiserver", "kube-controller-manager",
                            "kube-scheduler", "openshift-apiserver", "authentication",
                            "openshift-controller-manager"}

        if operators:
            for op in operators:
                op_name = op.get("metadata", {}).get("name", "")
                conditions = op.get("status", {}).get("conditions", [])
                is_progressing = any(
                    c.get("type") == "Progressing" and c.get("status") == "True"
                    for c in conditions
                )
                is_available = any(
                    c.get("type") == "Available" and c.get("status") == "True"
                    for c in conditions
                )

                # Only show if progressing AND not yet available
                if is_progressing and not is_available:
                    # Control plane operators roll out to master nodes
                    if op_name in control_plane_ops:
                        for node in nodes:
                            node_name = node.get("metadata", {}).get("name", "")
                            labels = node.get("metadata", {}).get("labels", {})
                            is_master = "node-role.kubernetes.io/master" in labels or \
                                       "node-role.kubernetes.io/control-plane" in labels
                            if is_master:
                                if node_name not in node_rollouts:
                                    node_rollouts[node_name] = []
                                if op_name not in node_rollouts[node_name]:
                                    node_rollouts[node_name].append(op_name)

        # Sort nodes: masters first, then workers
        def sort_key(n):
            name = n.get("metadata", {}).get("name", "")
            labels = n.get("metadata", {}).get("labels", {})
            is_master = "node-role.kubernetes.io/master" in labels or "node-role.kubernetes.io/control-plane" in labels
            return (0 if is_master else 1, name)

        for node in sorted(nodes, key=sort_key):
            name = node.get("metadata", {}).get("name", "unknown")
            labels = node.get("metadata", {}).get("labels", {})

            # Determine role
            if "node-role.kubernetes.io/master" in labels or "node-role.kubernetes.io/control-plane" in labels:
                role = "master"
            elif "node-role.kubernetes.io/worker" in labels:
                role = "worker"
            else:
                role = "unknown"

            # Get status
            conditions = node.get("status", {}).get("conditions", [])
            ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions)
            status = "Ready" if ready else "NotReady"

            # Get version
            version = node.get("status", {}).get("nodeInfo", {}).get("kubeletVersion", "")

            # Show rollout progress instead of age
            rollouts = node_rollouts.get(name, [])
            if rollouts:
                progress = ", ".join(rollouts[:2])
                if len(rollouts) > 2:
                    progress += f" +{len(rollouts)-2}"
            else:
                progress = "Complete"

            self.hosts_tree.insert("", tk.END, iid=name, values=(
                name, role, status, version, progress
            ))

            if rollouts:
                tag = "installing-in-progress"
            elif ready:
                tag = "ready"
            else:
                tag = "error"
            self.hosts_tree.tag_configure(tag, foreground=self.status_color(tag))
            self.hosts_tree.item(name, tags=(tag,))

    def update_operators_log(self, operators):
        """Update install log with operator status"""
        self.install_text.delete("1.0", tk.END)

        # Sort: unavailable first, then by name
        def sort_key(o):
            name = o.get("metadata", {}).get("name", "")
            conditions = o.get("status", {}).get("conditions", [])
            available = any(c.get("type") == "Available" and c.get("status") == "True" for c in conditions)
            return (0 if not available else 1, name)

        for op in sorted(operators, key=sort_key):
            name = op.get("metadata", {}).get("name", "unknown")
            conditions = op.get("status", {}).get("conditions", [])

            available = any(c.get("type") == "Available" and c.get("status") == "True" for c in conditions)
            progressing = any(c.get("type") == "Progressing" and c.get("status") == "True" for c in conditions)
            degraded = any(c.get("type") == "Degraded" and c.get("status") == "True" for c in conditions)

            # Get message if progressing
            msg = ""
            for c in conditions:
                if c.get("type") == "Progressing" and c.get("message"):
                    msg = c.get("message", "")[:60]
                    break

            if available and not progressing:
                self.install_text.insert(tk.END, f"✓ {name}\n", "done")
            elif degraded:
                self.install_text.insert(tk.END, f"✗ {name}\n", "error")
                if msg:
                    self.install_text.insert(tk.END, f"    {msg}\n", "info")
            elif progressing:
                self.install_text.insert(tk.END, f"● {name}\n", "stage")
                if msg:
                    self.install_text.insert(tk.END, f"    {msg}\n", "info")
            else:
                self.install_text.insert(tk.END, f"○ {name}\n", "info")

        self.install_text.see(tk.END)

    def on_host_select(self, event):
        selection = self.hosts_tree.selection()
        if not selection:
            return
        host_id = selection[0]
        self.selected_host_id = host_id
        self.show_host_details(host_id)

    def show_host_details(self, host_id):
        """Show validation details for a host"""
        host = self.hosts_data.get(host_id)
        if not host:
            return

        self.details_text.delete("1.0", tk.END)

        hostname = self.get_hostname(host)
        status = host.get("status", "unknown")
        self.details_text.insert(tk.END, f"=== {hostname} ({status}) ===\n\n")

        # Parse validations
        try:
            validations = json.loads(host.get("validations_info", "{}"))

            for category, checks in validations.items():
                self.details_text.insert(tk.END, f"\n[{category.upper()}]\n")

                for check in checks:
                    status = check.get("status", "unknown")
                    msg = check.get("message", "")
                    check_id = check.get("id", "")

                    symbol = {"success": "✓", "failure": "✗", "error": "!", "pending": "○"}.get(status, "?")
                    line = f"  {symbol} {check_id}: {msg}\n"

                    self.details_text.insert(tk.END, line, status)
        except Exception as e:
            self.details_text.insert(tk.END, f"Error parsing validations: {e}")

        # Show disk details
        try:
            inventory = json.loads(host.get("inventory", "{}"))
            disks = inventory.get("disks", [])

            self.details_text.insert(tk.END, f"\n\n[DISKS]\n")
            for d in disks:
                name = d.get("name")
                size_gb = d.get("size_bytes", 0) // (1024**3)
                eligible = d.get("installation_eligibility", {})
                is_eligible = eligible.get("eligible")
                reasons = eligible.get("not_eligible_reasons") or []

                status_tag = "success" if is_eligible else "failure"
                self.details_text.insert(tk.END, f"  {name}: {size_gb}GB - ", status_tag)

                if is_eligible:
                    self.details_text.insert(tk.END, "Eligible\n", "success")
                else:
                    self.details_text.insert(tk.END, f"Not eligible: {', '.join(reasons)}\n", "failure")
        except:
            pass

    def _load_node_ips(self):
        """Derive node IPs from agent-config.yaml host order and rendezvous IP"""
        try:
            if os.path.exists(AGENT_CONFIG_FILE):
                with open(AGENT_CONFIG_FILE, 'r') as f:
                    config = yaml.safe_load(f)
                rendezvous = config.get("rendezvousIP", "192.168.1.201")
                base_net, base_host = rendezvous.rsplit('.', 1)
                base_host = int(base_host)
                masters = [h for h in config.get("hosts", []) if h.get("role") == "master"]
                workers = [h for h in config.get("hosts", []) if h.get("role") != "master"]
                for i, host in enumerate(masters + workers):
                    hostname = host.get("hostname", "")
                    if hostname:
                        self.node_ips[hostname] = f"{base_net}.{base_host + i}"
                log(f"Node IPs: {self.node_ips}")
        except Exception as e:
            log(f"Failed to load node IPs: {e}")

    def _schedule_debug_check(self):
        """Schedule periodic debug checks"""
        if self.debug_auto_var.get():
            self.run_debug_check()
        self.root.after(DEBUG_CHECK_INTERVAL, self._schedule_debug_check)

    def run_debug_check(self):
        """Run debug checks on all nodes in parallel"""
        if self.debug_checking:
            return
        self.debug_checking = True
        self.root.after(0, lambda: self.debug_status_label.config(text="Checking..."))

        def do_checks():
            from concurrent.futures import ThreadPoolExecutor, as_completed
            results = {}

            with ThreadPoolExecutor(max_workers=6) as executor:
                futures = {}
                for hostname, ip in self.node_ips.items():
                    futures[executor.submit(self._ssh_check_node, hostname, ip)] = hostname

                for future in as_completed(futures):
                    hostname = futures[future]
                    try:
                        results[hostname] = future.result()
                    except Exception as e:
                        results[hostname] = [("error", f"Check failed: {e}")]

            # Also check cluster-level issues if in oc mode
            if self.mode == "oc":
                cluster_findings = self._check_cluster_issues()
                if cluster_findings:
                    results["_cluster"] = cluster_findings

            self.debug_findings = results
            self.last_debug_check = time.strftime('%H:%M:%S')
            self.debug_checking = False
            self.root.after(0, self._update_debug_display)

        threading.Thread(target=do_checks, daemon=True).start()

    def _ssh_check_node(self, hostname, ip):
        """Run debug checks on a single node, return list of (severity, message) tuples"""
        findings = []

        try:
            result = subprocess.run(
                ["ssh"] + SSH_OPTS + [f"core@{ip}", SSH_CHECK_CMD],
                capture_output=True, text=True, timeout=15
            )
        except subprocess.TimeoutExpired:
            return [("error", "SSH timeout (15s)")]
        except Exception as e:
            return [("error", f"SSH failed: {e}")]

        if result.returncode != 0 and not result.stdout:
            return [("error", "SSH unreachable")]

        output = result.stdout

        # Parse sections
        sections = {}
        current = None
        for line in output.split('\n'):
            if line.startswith("===") and line.endswith("==="):
                current = line.strip("=")
                sections[current] = []
            elif current:
                sections[current].append(line)

        # Check kubelet
        kubelet = '\n'.join(sections.get("KUBELET", [])).strip()
        if kubelet != "active":
            findings.append(("error", f"kubelet: {kubelet}"))

        # Check crio
        crio = '\n'.join(sections.get("CRIO", [])).strip()
        if crio != "active":
            findings.append(("error", f"crio: {crio}"))

        # Classify issues from journal
        issues = [l.strip() for l in sections.get("ISSUES", []) if l.strip()]
        cert_issues = []
        pull_issues = []
        other_issues = []
        for line in issues:
            lower = line.lower()
            if "x509" in lower or "certificate" in lower or "crypto" in lower:
                cert_issues.append(line)
            elif "errimagepull" in lower or "imagepullbackoff" in lower or "manifest unknown" in lower:
                pull_issues.append(line)
            else:
                other_issues.append(line)

        if cert_issues:
            findings.append(("error", f"TLS/cert errors ({len(cert_issues)})"))
            for line in cert_issues[-2:]:
                findings.append(("detail", f"  {line[:120]}"))
        if pull_issues:
            findings.append(("error", f"Image pull errors ({len(pull_issues)})"))
            for line in pull_issues[-2:]:
                findings.append(("detail", f"  {line[:120]}"))
        if other_issues:
            for line in other_issues[-2:]:
                findings.append(("warning", f"  {line[:120]}"))

        # Check MachineConfig
        mc = '\n'.join(sections.get("MC", [])).strip()
        if mc == "not-found":
            findings.append(("warning", "MachineConfig: currentconfig not found"))
        elif mc:
            findings.append(("info", f"MC: {mc}"))

        # Check disk usage
        for line in sections.get("DISK", []):
            parts = line.split()
            if len(parts) >= 5:
                try:
                    use_pct = int(parts[4].rstrip('%'))
                    mount = parts[5] if len(parts) > 5 else ""
                    if use_pct > 85:
                        findings.append(("warning", f"Disk {mount}: {use_pct}% used"))
                except (ValueError, IndexError):
                    pass

        # Check memory
        for line in sections.get("MEM", []):
            parts = line.split()
            if len(parts) >= 3:
                try:
                    total = int(parts[1])
                    used = int(parts[2])
                    pct = int(used / total * 100)
                    if pct > 90:
                        findings.append(("warning", f"Memory: {pct}% ({used}/{total} MB)"))
                except (ValueError, ZeroDivisionError):
                    pass

        # Check non-running containers
        containers = [l.strip() for l in sections.get("CONTAINERS", []) if l.strip()]
        if containers:
            findings.append(("warning", f"Non-running containers: {len(containers)}"))
            for line in containers[-3:]:
                findings.append(("detail", f"  {line[:120]}"))

        if not findings:
            findings.append(("ok", "No issues detected"))

        return findings

    def _check_cluster_issues(self):
        """Check for cluster-level issues via oc commands"""
        findings = []
        kubeconfig = os.path.join(SCRIPT_DIR, "gw", "auth", "kubeconfig")
        env = {**os.environ, "KUBECONFIG": kubeconfig}

        # Check for pending CSRs
        try:
            result = subprocess.run(
                ["oc", "get", "csr", "-o", "json"],
                capture_output=True, text=True, timeout=10, env=env
            )
            if result.returncode == 0:
                csrs = json.loads(result.stdout).get("items", [])
                pending = [c for c in csrs if not c.get("status", {}).get("conditions")]
                if pending:
                    findings.append(("warning", f"Pending CSRs: {len(pending)}"))
        except Exception:
            pass

        # Check MachineConfig annotations (desync detection)
        try:
            result = subprocess.run(
                ["oc", "get", "nodes", "-o", "json"],
                capture_output=True, text=True, timeout=10, env=env
            )
            if result.returncode == 0:
                nodes = json.loads(result.stdout).get("items", [])
                for node in nodes:
                    name = node.get("metadata", {}).get("name", "")
                    annotations = node.get("metadata", {}).get("annotations", {})
                    current = annotations.get("machineconfiguration.openshift.io/currentConfig", "")
                    desired = annotations.get("machineconfiguration.openshift.io/desiredConfig", "")
                    state = annotations.get("machineconfiguration.openshift.io/state", "")
                    if current and desired and current != desired:
                        findings.append(("error",
                            f"MC desync on {name}: current={current[:30]} desired={desired[:30]} state={state}"))
        except Exception:
            pass

        return findings

    def _update_debug_display(self):
        """Update the debug tab text widget with current findings"""
        self.debug_text.delete("1.0", tk.END)
        check_time = self.last_debug_check or "never"
        self.debug_status_label.config(text=f"Last: {check_time}")

        self.debug_text.insert(tk.END, f"Debug Check at {check_time}\n\n", "header")

        # Count total errors/warnings
        total_errors = 0
        total_warnings = 0

        # Show cluster-level issues first
        if "_cluster" in self.debug_findings:
            cluster = self.debug_findings["_cluster"]
            if cluster:
                self.debug_text.insert(tk.END, "Cluster\n", "header")
                for severity, msg in cluster:
                    self.debug_text.insert(tk.END, f"  {msg}\n", severity)
                    if severity == "error":
                        total_errors += 1
                    elif severity == "warning":
                        total_warnings += 1
                self.debug_text.insert(tk.END, "\n")

        # Show per-node findings (masters first, then workers)
        sorted_nodes = sorted(
            [(h, ip) for h, ip in self.node_ips.items()],
            key=lambda x: (0 if "control" in x[0] else 1, x[0])
        )

        for hostname, ip in sorted_nodes:
            findings = self.debug_findings.get(hostname, [])
            short_name = hostname.split('.')[0]

            # Determine node-level severity
            has_errors = any(s == "error" for s, _ in findings)
            has_warnings = any(s == "warning" for s, _ in findings)
            is_ok = all(s in ("ok", "info") for s, _ in findings)

            if has_errors:
                node_tag = "error"
                total_errors += sum(1 for s, _ in findings if s == "error")
            elif has_warnings:
                node_tag = "warning"
                total_warnings += sum(1 for s, _ in findings if s == "warning")
            elif is_ok:
                node_tag = "ok"
            else:
                node_tag = "info"

            self.debug_text.insert(tk.END, f"{short_name} ", "header")
            self.debug_text.insert(tk.END, f"({ip})\n", "info")

            for severity, msg in findings:
                self.debug_text.insert(tk.END, f"  {msg}\n", severity)

            self.debug_text.insert(tk.END, "\n")

        # Summary line
        if total_errors == 0 and total_warnings == 0:
            self.debug_text.insert(tk.END, "All nodes healthy\n", "ok")
        else:
            summary = []
            if total_errors:
                summary.append(f"{total_errors} errors")
            if total_warnings:
                summary.append(f"{total_warnings} warnings")
            self.debug_text.insert(tk.END, f"Found: {', '.join(summary)}\n", "error" if total_errors else "warning")

    def run_gather_debug(self):
        """Run gatherdebug.sh in background"""
        if not os.path.exists(GATHERDEBUG_SCRIPT):
            self.debug_text.insert(tk.END, f"\nERROR: {GATHERDEBUG_SCRIPT} not found\n", "error")
            return

        self.debug_status_label.config(text="Gathering debug...")
        self.debug_text.insert(tk.END, f"\nRunning gatherdebug.sh...\n", "header")

        def do_gather():
            try:
                result = subprocess.run(
                    ["bash", GATHERDEBUG_SCRIPT],
                    capture_output=True, text=True, timeout=300,
                    cwd=SCRIPT_DIR
                )
                output = result.stdout
                # Find the tarball path in output
                for line in output.split('\n'):
                    if "Tarball:" in line:
                        self.root.after(0, lambda l=line: self.debug_text.insert(tk.END, f"{l.strip()}\n", "ok"))
                    elif "Debug gathered:" in line:
                        self.root.after(0, lambda l=line: self.debug_text.insert(tk.END, f"{l.strip()}\n", "info"))

                if result.returncode == 0:
                    self.root.after(0, lambda: self.debug_status_label.config(text="Gather complete"))
                else:
                    self.root.after(0, lambda: self.debug_text.insert(
                        tk.END, f"gatherdebug.sh failed (rc={result.returncode})\n", "error"))
                    self.root.after(0, lambda: self.debug_status_label.config(text="Gather failed"))
            except subprocess.TimeoutExpired:
                self.root.after(0, lambda: self.debug_text.insert(
                    tk.END, "gatherdebug.sh timed out (5m)\n", "error"))
                self.root.after(0, lambda: self.debug_status_label.config(text="Gather timeout"))
            except Exception as e:
                self.root.after(0, lambda: self.debug_text.insert(
                    tk.END, f"Error: {e}\n", "error"))

        threading.Thread(target=do_gather, daemon=True).start()

    def start_event_streamer(self):
        """Start background thread for fast event polling"""
        def stream_events():
            self.event_streamer_running = True
            log("Event streamer started")
            while self.event_streamer_running:
                try:
                    token = get_auth_token()
                    if not token or not self.cluster_id:
                        log(f"Event streamer waiting: token={bool(token)}, cluster_id={self.cluster_id}")
                        time.sleep(EVENT_POLL_INTERVAL)
                        continue

                    headers = {"Authorization": token}
                    resp = requests.get(
                        f"{API_URL}/events",
                        params={"cluster_id": self.cluster_id},
                        headers=headers,
                        timeout=5,
                        verify=False
                    )

                    if resp.status_code == 200:
                        events = resp.json()
                        new_count = 0
                        for event in events:
                            event_id = event.get("event_id")
                            if event_id and event_id not in self.seen_event_ids:
                                self.seen_event_ids.add(event_id)
                                msg = event.get("message", "")
                                severity = event.get("severity", "info")
                                log_event(msg, severity)
                                new_count += 1
                        if new_count > 0:
                            log(f"Event streamer: {new_count} new events")
                    else:
                        log(f"Event streamer: API returned {resp.status_code}")

                except Exception as e:
                    log(f"Event streamer error: {e}")

                time.sleep(EVENT_POLL_INTERVAL)

        thread = threading.Thread(target=stream_events, daemon=True)
        thread.start()


def main():
    # Suppress SSL warnings
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    root = tk.Tk()
    app = AgentMonitor(root)
    root.mainloop()


if __name__ == "__main__":
    main()
