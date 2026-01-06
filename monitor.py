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

        self.setup_ui()
        self.refresh()

    def setup_ui(self):
        # Cluster status frame
        cluster_frame = ttk.LabelFrame(self.root, text="Cluster Status", padding=10)
        cluster_frame.pack(fill=tk.X, padx=10, pady=5)

        self.cluster_status = ttk.Label(cluster_frame, text="Loading...", font=("Helvetica", 14, "bold"))
        self.cluster_status.pack(anchor=tk.W)

        self.cluster_info = ttk.Label(cluster_frame, text="", wraplength=850)
        self.cluster_info.pack(anchor=tk.W)

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

        # Validation details frame
        details_frame = ttk.LabelFrame(self.root, text="Validation Details", padding=10)
        details_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=5)

        self.details_text = tk.Text(details_frame, height=15, wrap=tk.WORD)
        scrollbar = ttk.Scrollbar(details_frame, orient=tk.VERTICAL, command=self.details_text.yview)
        self.details_text.configure(yscrollcommand=scrollbar.set)

        self.details_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        # Configure tags for coloring
        self.details_text.tag_configure("success", foreground="green")
        self.details_text.tag_configure("failure", foreground="red")
        self.details_text.tag_configure("error", foreground="goldenrod")
        self.details_text.tag_configure("pending", foreground="gray")

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

    def refresh(self):
        def do_refresh():
            cluster = self.get_cluster()

            if cluster:
                self.cluster_id = cluster.get("id")
                status = cluster.get("status", "unknown")
                status_info = cluster.get("status_info", "")

                # Update cluster status
                self.root.after(0, lambda: self.cluster_status.config(
                    text=f"Status: {status.upper()}",
                    foreground=self.status_color(status)
                ))
                self.root.after(0, lambda: self.cluster_info.config(text=status_info))

                # Get hosts
                hosts = self.get_hosts(self.cluster_id)
                self.root.after(0, lambda: self.update_hosts(hosts))

                self.root.after(0, lambda: self.status_label.config(
                    text=f"Last update: {time.strftime('%H:%M:%S')}"
                ))
            else:
                self.root.after(0, lambda: self.cluster_status.config(
                    text="Waiting on API...",
                    foreground="goldenrod"
                ))
                self.root.after(0, lambda: self.status_label.config(
                    text="Waiting on API..."
                ))

        # Run in background thread
        threading.Thread(target=do_refresh, daemon=True).start()

        # Schedule next refresh
        self.root.after(REFRESH_INTERVAL, self.refresh)

    def status_color(self, status):
        colors = {
            "ready": "green",
            "installed": "green",
            "installing": "blue",
            "preparing-for-installation": "blue",
            "pending-for-input": "goldenrod",
            "insufficient": "red",
            "error": "red",
            "known": "green",
        }
        return colors.get(status, "black")

    def update_hosts(self, hosts):
        # Clear existing items
        for item in self.hosts_tree.get_children():
            self.hosts_tree.delete(item)

        # Store hosts data for detail view
        self.hosts_data = {}

        for host in hosts:
            host_id = host.get("id")
            hostname = host.get("requested_hostname", "unknown")
            role = host.get("role", "auto-assign")
            status = host.get("status", "unknown")

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

            # Get progress
            progress = host.get("progress", {})
            stage = progress.get("current_stage", "")

            self.hosts_tree.insert("", tk.END, iid=host_id, values=(
                hostname, role, status, disk_info, stage
            ))

            # Color by status
            self.hosts_tree.tag_configure(status, foreground=self.status_color(status))
            self.hosts_tree.item(host_id, tags=(status,))

            # Store for details
            self.hosts_data[host_id] = host

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
