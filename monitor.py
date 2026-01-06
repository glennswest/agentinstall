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

# Configuration
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(SCRIPT_DIR, "gw", ".openshift_install_state.json")
API_URL = "http://192.168.1.201:8090/api/assisted-install/v2"
REFRESH_INTERVAL = 5000  # ms


def get_auth_token():
    """Read auth token from state file"""
    try:
        with open(STATE_FILE, 'r') as f:
            state = json.load(f)
            return state.get("*gencrypto.AuthConfig", {}).get("UserAuthToken", "")
    except:
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

        self.setup_ui()
        self.refresh()

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

        # Validation tab
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
                return None
            headers = {"Authorization": token}
            response = requests.get(f"{API_URL}{endpoint}", headers=headers, timeout=5, verify=False)
            if response.status_code == 200:
                return response.json()
            return None
        except Exception as e:
            return None

    def get_cluster(self):
        clusters = self.api_request("/clusters")
        if clusters and isinstance(clusters, list) and len(clusters) > 0:
            return clusters[0]
        return None

    def get_hosts(self, cluster_id):
        return self.api_request(f"/clusters/{cluster_id}/hosts") or []

    def get_events(self, cluster_id):
        return self.api_request(f"/events?cluster_id={cluster_id}") or []

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
        def do_refresh():
            if self.mode == "api":
                cluster = self.get_cluster()

                if cluster:
                    self.api_fail_count = 0
                    self.cluster_id = cluster.get("id")
                    status = cluster.get("status", "unknown")
                    status_info = cluster.get("status_info", "")
                    progress = cluster.get("progress", {})
                    total_pct = progress.get("total_percentage", 0)

                    # Update cluster status with percentage
                    if total_pct > 0:
                        status_text = f"{status.upper()} ({total_pct}%)"
                    else:
                        status_text = status.upper()

                    self.root.after(0, lambda t=status_text, s=status: self.cluster_status.config(
                        text=t,
                        foreground=self.status_color(s)
                    ))
                    self.root.after(0, lambda: self.cluster_info.config(text=status_info))

                    # Update progress bar
                    self.root.after(0, lambda p=total_pct: self.progress_bar.config(value=p))
                    self.root.after(0, lambda p=total_pct: self.progress_label.config(text=f"{p}%"))

                    # Get hosts
                    hosts = self.get_hosts(self.cluster_id)
                    self.root.after(0, lambda: self.update_hosts(hosts))

                    # Switch to install tab and update install log when installing
                    if status in ("installing", "finalizing") and not self.switched_to_install:
                        self.root.after(0, lambda: self.notebook.select(1))
                        self.switched_to_install = True

                    if status in ("installing", "finalizing", "installed"):
                        events = self.get_events(self.cluster_id)
                        self.root.after(0, lambda e=events: self.update_install_log(e))

                    self.root.after(0, lambda: self.status_label.config(
                        text=f"Last update: {time.strftime('%H:%M:%S')}"
                    ))
                else:
                    self.api_fail_count += 1
                    # After 3 failures, switch to oc mode
                    if self.api_fail_count >= 3:
                        self.mode = "oc"
                        self.root.after(0, lambda: self.cluster_info.config(
                            text="Switched to cluster monitoring (bootstrap complete)"
                        ))
                    else:
                        self.root.after(0, lambda: self.cluster_status.config(
                            text="WAITING...",
                            foreground="#8b7355"
                        ))
                        self.root.after(0, lambda: self.status_label.config(
                            text="Waiting on API..."
                        ))

            if self.mode == "oc":
                self.refresh_oc_mode()

        # Run in background thread
        threading.Thread(target=do_refresh, daemon=True).start()

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

        # Update install log with operators
        self.root.after(0, lambda o=operators: self.update_operators_log(o))

        self.root.after(0, lambda: self.status_label.config(
            text=f"Last update: {time.strftime('%H:%M:%S')} (oc)"
        ))

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

        for host in sorted(hosts, key=sort_key):
            host_id = host.get("id")
            hostname = host.get("requested_hostname") or "unknown"
            role = host.get("role", "auto-assign")
            status = host.get("status", "unknown")
            status_info = host.get("status_info", "")

            # Try to get hostname from inventory if not set
            try:
                inventory = json.loads(host.get("inventory", "{}"))
                if hostname == "unknown" and inventory.get("hostname"):
                    hostname = inventory.get("hostname")
                # Get IP if still unknown
                if hostname == "unknown":
                    ifaces = inventory.get("interfaces", [])
                    for iface in ifaces:
                        addrs = iface.get("ipv4_addresses", [])
                        if addrs:
                            hostname = addrs[0].split("/")[0]
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

                if is_progressing:
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
        host = self.hosts_data.get(host_id)
        if not host:
            return

        self.details_text.delete("1.0", tk.END)

        hostname = host.get("requested_hostname", "unknown")
        self.details_text.insert(tk.END, f"=== {hostname} ===\n\n")

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


def main():
    # Suppress SSL warnings
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    root = tk.Tk()
    app = AgentMonitor(root)
    root.mainloop()


if __name__ == "__main__":
    main()
