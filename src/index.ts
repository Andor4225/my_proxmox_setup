#!/usr/bin/env node
/**
 * Proxmox VE MCP Server
 * Provides tools for managing Proxmox VMs, containers, snapshots, and networking.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { config } from "dotenv";
import { resolve } from "path";
import { execSync } from "child_process";
import { ProxmoxClient } from "./proxmox-client.js";

// Load .env from the project root
config({ path: resolve(import.meta.dirname, "..", ".env") });

const proxmox = new ProxmoxClient({
  host: process.env.PROXMOX_HOST || "192.168.10.147",
  port: parseInt(process.env.PROXMOX_PORT || "8006"),
  tokenId: process.env.PROXMOX_TOKEN_ID || "",
  tokenSecret: process.env.PROXMOX_TOKEN_SECRET || "",
  verifySsl: process.env.PROXMOX_VERIFY_SSL === "true",
});

const DEFAULT_NODE = "pve";

const server = new McpServer({
  name: "proxmox",
  version: "1.0.0",
});

// ── Helper ──

function formatBytes(bytes: number): string {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  let val = bytes;
  while (val >= 1024 && i < units.length - 1) {
    val /= 1024;
    i++;
  }
  return `${val.toFixed(1)} ${units[i]}`;
}

function sshExec(command: string): string {
  const host = process.env.PROXMOX_HOST || "192.168.10.147";
  const sshCmd = `ssh -o BatchMode=yes -o ConnectTimeout=10 root@${host} ${JSON.stringify(command)}`;
  return execSync(sshCmd, { encoding: "utf-8", timeout: 120000 }).trim();
}

// ── Resource: Cluster Overview ──

server.resource("cluster-status", "proxmox://cluster/status", async (uri) => {
  const resources = await proxmox.getClusterResources();
  const nodes = resources.filter((r) => r.type === "node");
  const vms = resources.filter((r) => r.type === "qemu");
  const cts = resources.filter((r) => r.type === "lxc");
  const storage = resources.filter((r) => r.type === "storage");

  let text = "# Proxmox Cluster Status\n\n";

  text += "## Nodes\n";
  for (const n of nodes) {
    text += `- **${n.node}**: ${n.status} | CPU: ${((n.cpu as number) * 100).toFixed(1)}% | RAM: ${formatBytes(n.mem as number)}/${formatBytes(n.maxmem as number)}\n`;
  }

  text += "\n## Virtual Machines\n";
  for (const vm of vms) {
    text += `- **${vm.name}** (VMID ${vm.vmid}): ${vm.status} | CPU: ${((vm.cpu as number) * 100).toFixed(1)}% | RAM: ${formatBytes(vm.mem as number)}/${formatBytes(vm.maxmem as number)}\n`;
  }

  if (cts.length > 0) {
    text += "\n## Containers\n";
    for (const ct of cts) {
      text += `- **${ct.name}** (CTID ${ct.vmid}): ${ct.status}\n`;
    }
  }

  text += "\n## Storage\n";
  for (const s of storage) {
    text += `- **${s.storage}** (${s.plugintype}): ${formatBytes(s.disk as number)}/${formatBytes(s.maxdisk as number)} used\n`;
  }

  return { contents: [{ uri: uri.href, mimeType: "text/markdown", text }] };
});

// ── Tool: List VMs ──

server.tool(
  "list_vms",
  "List all QEMU virtual machines on a Proxmox node",
  { node: z.string().default(DEFAULT_NODE).describe("Proxmox node name") },
  async ({ node }) => {
    const vms = await proxmox.listVMs(node);
    const lines = vms.map(
      (vm) =>
        `VMID ${vm.vmid} | ${vm.name} | ${vm.status} | CPU: ${((vm.cpu || 0) * 100).toFixed(1)}% | RAM: ${formatBytes(vm.mem || 0)}/${formatBytes(vm.maxmem || 0)}`
    );
    return {
      content: [
        {
          type: "text",
          text: lines.length > 0 ? lines.join("\n") : "No VMs found.",
        },
      ],
    };
  }
);

// ── Tool: List Containers ──

server.tool(
  "list_containers",
  "List all LXC containers on a Proxmox node",
  { node: z.string().default(DEFAULT_NODE).describe("Proxmox node name") },
  async ({ node }) => {
    const cts = await proxmox.listContainers(node);
    const lines = cts.map(
      (ct) =>
        `CTID ${ct.vmid} | ${ct.name} | ${ct.status} | RAM: ${formatBytes(ct.mem || 0)}/${formatBytes(ct.maxmem || 0)}`
    );
    return {
      content: [
        {
          type: "text",
          text: lines.length > 0 ? lines.join("\n") : "No containers found.",
        },
      ],
    };
  }
);

// ── Tool: Get VM/CT Status ──

server.tool(
  "get_status",
  "Get detailed status of a VM or container",
  {
    vmid: z.number().describe("VM or container ID"),
    type: z.enum(["qemu", "lxc"]).default("qemu").describe("Resource type"),
    node: z.string().default(DEFAULT_NODE).describe("Proxmox node name"),
  },
  async ({ vmid, type, node }) => {
    const status =
      type === "qemu"
        ? await proxmox.getVMStatus(node, vmid)
        : await proxmox.getContainerStatus(node, vmid);
    return {
      content: [
        { type: "text", text: JSON.stringify(status, null, 2) },
      ],
    };
  }
);

// ── Tool: Get VM Config ──

server.tool(
  "get_vm_config",
  "Get the configuration of a QEMU VM",
  {
    vmid: z.number().describe("VM ID"),
    node: z.string().default(DEFAULT_NODE).describe("Proxmox node name"),
  },
  async ({ vmid, node }) => {
    const config = await proxmox.getVMConfig(node, vmid);
    return {
      content: [
        { type: "text", text: JSON.stringify(config, null, 2) },
      ],
    };
  }
);

// ── Tool: Start VM/CT ──

server.tool(
  "start",
  "Start a VM or container",
  {
    vmid: z.number().describe("VM or container ID"),
    type: z.enum(["qemu", "lxc"]).default("qemu").describe("Resource type"),
    node: z.string().default(DEFAULT_NODE).describe("Proxmox node name"),
  },
  async ({ vmid, type, node }) => {
    const upid =
      type === "qemu"
        ? await proxmox.startVM(node, vmid)
        : await proxmox.startContainer(node, vmid);
    return {
      content: [{ type: "text", text: `Started ${type} ${vmid}. Task: ${upid}` }],
    };
  }
);

// ── Tool: Stop VM/CT ──

server.tool(
  "stop",
  "Stop (force) a VM or container",
  {
    vmid: z.number().describe("VM or container ID"),
    type: z.enum(["qemu", "lxc"]).default("qemu").describe("Resource type"),
    node: z.string().default(DEFAULT_NODE).describe("Proxmox node name"),
  },
  async ({ vmid, type, node }) => {
    const upid =
      type === "qemu"
        ? await proxmox.stopVM(node, vmid)
        : await proxmox.stopContainer(node, vmid);
    return {
      content: [{ type: "text", text: `Stopped ${type} ${vmid}. Task: ${upid}` }],
    };
  }
);

// ── Tool: Shutdown VM ──

server.tool(
  "shutdown",
  "Gracefully shutdown a QEMU VM (sends ACPI shutdown signal)",
  {
    vmid: z.number().describe("VM ID"),
    node: z.string().default(DEFAULT_NODE).describe("Proxmox node name"),
  },
  async ({ vmid, node }) => {
    const upid = await proxmox.shutdownVM(node, vmid);
    return {
      content: [{ type: "text", text: `Shutdown signal sent to VM ${vmid}. Task: ${upid}` }],
    };
  }
);

// ── Tool: Create Snapshot ──

server.tool(
  "create_snapshot",
  "Create a snapshot of a VM or container (useful before pentesting to restore clean state)",
  {
    vmid: z.number().describe("VM or container ID"),
    name: z.string().describe("Snapshot name (no spaces)"),
    description: z.string().default("").describe("Snapshot description"),
    type: z.enum(["qemu", "lxc"]).default("qemu").describe("Resource type"),
    node: z.string().default(DEFAULT_NODE).describe("Proxmox node name"),
  },
  async ({ vmid, name, description, type, node }) => {
    const upid = await proxmox.createSnapshot(node, vmid, name, description, type);
    return {
      content: [
        {
          type: "text",
          text: `Snapshot '${name}' created for ${type} ${vmid}. Task: ${upid}`,
        },
      ],
    };
  }
);

// ── Tool: List Snapshots ──

server.tool(
  "list_snapshots",
  "List all snapshots of a VM or container",
  {
    vmid: z.number().describe("VM or container ID"),
    type: z.enum(["qemu", "lxc"]).default("qemu").describe("Resource type"),
    node: z.string().default(DEFAULT_NODE).describe("Proxmox node name"),
  },
  async ({ vmid, type, node }) => {
    const snaps = await proxmox.listSnapshots(node, vmid, type);
    const lines = snaps.map(
      (s) =>
        `${s.name}${s.description ? ` — ${s.description}` : ""}${s.snaptime ? ` (${new Date(s.snaptime * 1000).toISOString()})` : ""}`
    );
    return {
      content: [
        {
          type: "text",
          text: lines.length > 0 ? lines.join("\n") : "No snapshots found.",
        },
      ],
    };
  }
);

// ── Tool: Rollback Snapshot ──

server.tool(
  "rollback_snapshot",
  "Rollback a VM or container to a previous snapshot",
  {
    vmid: z.number().describe("VM or container ID"),
    name: z.string().describe("Snapshot name to rollback to"),
    type: z.enum(["qemu", "lxc"]).default("qemu").describe("Resource type"),
    node: z.string().default(DEFAULT_NODE).describe("Proxmox node name"),
  },
  async ({ vmid, name, type, node }) => {
    const upid = await proxmox.rollbackSnapshot(node, vmid, name, type);
    return {
      content: [
        {
          type: "text",
          text: `Rolled back ${type} ${vmid} to snapshot '${name}'. Task: ${upid}`,
        },
      ],
    };
  }
);

// ── Tool: List Storage ──

server.tool(
  "list_storage",
  "List available storage on a Proxmox node",
  { node: z.string().default(DEFAULT_NODE).describe("Proxmox node name") },
  async ({ node }) => {
    const storage = await proxmox.listStorage(node);
    return {
      content: [
        { type: "text", text: JSON.stringify(storage, null, 2) },
      ],
    };
  }
);

// ── Tool: List Networks ──

server.tool(
  "list_networks",
  "List network interfaces on a Proxmox node",
  { node: z.string().default(DEFAULT_NODE).describe("Proxmox node name") },
  async ({ node }) => {
    const nets = await proxmox.listNetworks(node);
    const lines = nets.map(
      (n) =>
        `${n.iface} (${n.type})${n.active ? " [active]" : ""}${n.address ? ` ${n.address}/${n.netmask}` : ""}${n.bridge_ports ? ` ports: ${n.bridge_ports}` : ""}`
    );
    return {
      content: [{ type: "text", text: lines.join("\n") }],
    };
  }
);

// ── Tool: Cluster Resources ──

server.tool(
  "cluster_resources",
  "Get an overview of all cluster resources (nodes, VMs, containers, storage)",
  {
    type: z
      .enum(["node", "qemu", "lxc", "storage"])
      .optional()
      .describe("Filter by resource type"),
  },
  async ({ type }) => {
    const resources = await proxmox.getClusterResources(type);
    return {
      content: [
        { type: "text", text: JSON.stringify(resources, null, 2) },
      ],
    };
  }
);

// ── Tool: Execute SSH Command ──

server.tool(
  "exec_command",
  "Execute a shell command on the Proxmox host via SSH (for operations not covered by the API)",
  {
    command: z.string().describe("Shell command to execute on the Proxmox host"),
  },
  async ({ command }) => {
    try {
      const output = sshExec(command);
      return {
        content: [{ type: "text", text: output || "(no output)" }],
      };
    } catch (err) {
      const error = err as Error & { stderr?: string };
      return {
        content: [
          {
            type: "text",
            text: `Error: ${error.stderr || error.message}`,
          },
        ],
        isError: true,
      };
    }
  }
);

// ── Tool: List Docker Containers (on Proxmox host or inside a VM) ──

server.tool(
  "list_docker",
  "List Docker containers running on the Proxmox host",
  {},
  async () => {
    try {
      const output = sshExec("docker ps --format 'table {{.ID}}\\t{{.Names}}\\t{{.Status}}\\t{{.Ports}}\\t{{.Image}}'");
      return {
        content: [{ type: "text", text: output }],
      };
    } catch (err) {
      const error = err as Error & { stderr?: string };
      return {
        content: [
          {
            type: "text",
            text: `Error listing Docker containers: ${error.stderr || error.message}`,
          },
        ],
        isError: true,
      };
    }
  }
);

// ── Tool: Manage Docker Container ──

server.tool(
  "docker_manage",
  "Start, stop, restart, or remove a Docker container on the Proxmox host",
  {
    action: z.enum(["start", "stop", "restart", "rm", "logs"]).describe("Action to perform"),
    container: z.string().describe("Container name or ID"),
    tail: z.number().default(50).describe("Number of log lines to tail (for logs action)"),
  },
  async ({ action, container, tail }) => {
    try {
      let cmd: string;
      if (action === "logs") {
        cmd = `docker logs --tail ${tail} ${container}`;
      } else {
        cmd = `docker ${action} ${container}`;
      }
      const output = sshExec(cmd);
      return {
        content: [{ type: "text", text: output || `Docker ${action} on '${container}' completed.` }],
      };
    } catch (err) {
      const error = err as Error & { stderr?: string };
      return {
        content: [
          {
            type: "text",
            text: `Error: ${error.stderr || error.message}`,
          },
        ],
        isError: true,
      };
    }
  }
);

// ── Tool: Deploy Docker Container ──

server.tool(
  "docker_run",
  "Deploy a new Docker container on the Proxmox host",
  {
    image: z.string().describe("Docker image to run (e.g., 'bkimminich/juice-shop')"),
    name: z.string().describe("Container name"),
    ports: z.string().optional().describe("Port mapping (e.g., '3000:3000')"),
    env: z.array(z.string()).optional().describe("Environment variables (e.g., ['KEY=value'])"),
    detach: z.boolean().default(true).describe("Run in detached mode"),
    extra_args: z.string().optional().describe("Additional docker run arguments"),
  },
  async ({ image, name, ports, env, detach, extra_args }) => {
    try {
      let cmd = `docker run`;
      if (detach) cmd += " -d";
      cmd += ` --name ${name}`;
      if (ports) cmd += ` -p ${ports}`;
      if (env) {
        for (const e of env) {
          cmd += ` -e ${e}`;
        }
      }
      if (extra_args) cmd += ` ${extra_args}`;
      cmd += ` ${image}`;

      const output = sshExec(cmd);
      return {
        content: [
          {
            type: "text",
            text: `Container '${name}' deployed from ${image}.\nContainer ID: ${output}`,
          },
        ],
      };
    } catch (err) {
      const error = err as Error & { stderr?: string };
      return {
        content: [
          {
            type: "text",
            text: `Error deploying container: ${error.stderr || error.message}`,
          },
        ],
        isError: true,
      };
    }
  }
);

// ── Tool: List Recent Tasks ──

server.tool(
  "list_tasks",
  "List recent tasks/operations on the Proxmox node",
  { node: z.string().default(DEFAULT_NODE).describe("Proxmox node name") },
  async ({ node }) => {
    const tasks = await proxmox.listTasks(node);
    const recent = tasks.slice(0, 10);
    const lines = recent.map(
      (t) =>
        `${t.type} | ${t.status} | ${t.user} | ${new Date((t.starttime as number) * 1000).toISOString()} | ${t.upid}`
    );
    return {
      content: [
        {
          type: "text",
          text: lines.length > 0 ? lines.join("\n") : "No recent tasks.",
        },
      ],
    };
  }
);

// ── Start Server ──

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Proxmox MCP server running on stdio");
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
