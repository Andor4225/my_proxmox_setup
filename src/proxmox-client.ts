/**
 * Proxmox VE API Client
 * Wraps the Proxmox REST API with typed methods for VM/CT management.
 */

export interface ProxmoxConfig {
  host: string;
  port: number;
  tokenId: string;
  tokenSecret: string;
  verifySsl: boolean;
}

export interface VMStatus {
  vmid: number;
  name: string;
  status: string;
  cpu: number;
  mem: number;
  maxmem: number;
  maxdisk: number;
  uptime: number;
  type: string;
  node: string;
}

export interface NodeStatus {
  node: string;
  status: string;
  cpu: number;
  maxcpu: number;
  mem: number;
  maxmem: number;
  disk: number;
  maxdisk: number;
  uptime: number;
}

export interface Snapshot {
  name: string;
  description: string;
  snaptime?: number;
  parent?: string;
}

export interface NetworkInterface {
  iface: string;
  type: string;
  active?: number;
  method?: string;
  address?: string;
  netmask?: string;
  gateway?: string;
  bridge_ports?: string;
}

export class ProxmoxClient {
  private baseUrl: string;
  private authHeader: string;

  constructor(private config: ProxmoxConfig) {
    this.baseUrl = `https://${config.host}:${config.port}/api2/json`;
    this.authHeader = `PVEAPIToken=${config.tokenId}=${config.tokenSecret}`;
  }

  private async request<T>(
    method: string,
    path: string,
    body?: Record<string, unknown>
  ): Promise<T> {
    const url = `${this.baseUrl}${path}`;
    const options: RequestInit = {
      method,
      headers: {
        Authorization: this.authHeader,
        "Content-Type": "application/json",
      },
    };

    if (body && (method === "POST" || method === "PUT")) {
      options.body = JSON.stringify(body);
    }

    // Disable SSL verification for self-signed certs
    if (!this.config.verifySsl) {
      process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
    }

    const response = await fetch(url, options);

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(
        `Proxmox API error ${response.status}: ${errorText}`
      );
    }

    const json = (await response.json()) as { data: T };
    return json.data;
  }

  // ── Node Operations ──

  async getNodes(): Promise<NodeStatus[]> {
    return this.request<NodeStatus[]>("GET", "/nodes");
  }

  async getNodeStatus(node: string): Promise<NodeStatus> {
    return this.request<NodeStatus>("GET", `/nodes/${node}/status`);
  }

  // ── VM (QEMU) Operations ──

  async listVMs(node: string): Promise<VMStatus[]> {
    return this.request<VMStatus[]>("GET", `/nodes/${node}/qemu`);
  }

  async getVMStatus(node: string, vmid: number): Promise<VMStatus> {
    return this.request<VMStatus>(
      "GET",
      `/nodes/${node}/qemu/${vmid}/status/current`
    );
  }

  async startVM(node: string, vmid: number): Promise<string> {
    return this.request<string>(
      "POST",
      `/nodes/${node}/qemu/${vmid}/status/start`
    );
  }

  async stopVM(node: string, vmid: number): Promise<string> {
    return this.request<string>(
      "POST",
      `/nodes/${node}/qemu/${vmid}/status/stop`
    );
  }

  async shutdownVM(node: string, vmid: number): Promise<string> {
    return this.request<string>(
      "POST",
      `/nodes/${node}/qemu/${vmid}/status/shutdown`
    );
  }

  async rebootVM(node: string, vmid: number): Promise<string> {
    return this.request<string>(
      "POST",
      `/nodes/${node}/qemu/${vmid}/status/reboot`
    );
  }

  async getVMConfig(node: string, vmid: number): Promise<Record<string, unknown>> {
    return this.request<Record<string, unknown>>(
      "GET",
      `/nodes/${node}/qemu/${vmid}/config`
    );
  }

  async createVM(
    node: string,
    vmid: number,
    params: Record<string, unknown>
  ): Promise<string> {
    return this.request<string>("POST", `/nodes/${node}/qemu`, {
      vmid,
      ...params,
    });
  }

  async deleteVM(node: string, vmid: number): Promise<string> {
    return this.request<string>(
      "DELETE",
      `/nodes/${node}/qemu/${vmid}`
    );
  }

  // ── Container (LXC) Operations ──

  async listContainers(node: string): Promise<VMStatus[]> {
    return this.request<VMStatus[]>("GET", `/nodes/${node}/lxc`);
  }

  async getContainerStatus(node: string, vmid: number): Promise<VMStatus> {
    return this.request<VMStatus>(
      "GET",
      `/nodes/${node}/lxc/${vmid}/status/current`
    );
  }

  async startContainer(node: string, vmid: number): Promise<string> {
    return this.request<string>(
      "POST",
      `/nodes/${node}/lxc/${vmid}/status/start`
    );
  }

  async stopContainer(node: string, vmid: number): Promise<string> {
    return this.request<string>(
      "POST",
      `/nodes/${node}/lxc/${vmid}/status/stop`
    );
  }

  async createContainer(
    node: string,
    vmid: number,
    params: Record<string, unknown>
  ): Promise<string> {
    return this.request<string>("POST", `/nodes/${node}/lxc`, {
      vmid,
      ...params,
    });
  }

  async deleteContainer(node: string, vmid: number): Promise<string> {
    return this.request<string>(
      "DELETE",
      `/nodes/${node}/lxc/${vmid}`
    );
  }

  // ── Snapshot Operations ──

  async listSnapshots(
    node: string,
    vmid: number,
    type: "qemu" | "lxc" = "qemu"
  ): Promise<Snapshot[]> {
    return this.request<Snapshot[]>(
      "GET",
      `/nodes/${node}/${type}/${vmid}/snapshot`
    );
  }

  async createSnapshot(
    node: string,
    vmid: number,
    name: string,
    description: string,
    type: "qemu" | "lxc" = "qemu"
  ): Promise<string> {
    return this.request<string>(
      "POST",
      `/nodes/${node}/${type}/${vmid}/snapshot`,
      { snapname: name, description }
    );
  }

  async rollbackSnapshot(
    node: string,
    vmid: number,
    name: string,
    type: "qemu" | "lxc" = "qemu"
  ): Promise<string> {
    return this.request<string>(
      "POST",
      `/nodes/${node}/${type}/${vmid}/snapshot/${name}/rollback`
    );
  }

  async deleteSnapshot(
    node: string,
    vmid: number,
    name: string,
    type: "qemu" | "lxc" = "qemu"
  ): Promise<string> {
    return this.request<string>(
      "DELETE",
      `/nodes/${node}/${type}/${vmid}/snapshot/${name}`
    );
  }

  // ── Network Operations ──

  async listNetworks(node: string): Promise<NetworkInterface[]> {
    return this.request<NetworkInterface[]>(
      "GET",
      `/nodes/${node}/network`
    );
  }

  // ── Storage Operations ──

  async listStorage(node: string): Promise<Record<string, unknown>[]> {
    return this.request<Record<string, unknown>[]>(
      "GET",
      `/nodes/${node}/storage`
    );
  }

  async listStorageContent(
    node: string,
    storage: string
  ): Promise<Record<string, unknown>[]> {
    return this.request<Record<string, unknown>[]>(
      "GET",
      `/nodes/${node}/storage/${storage}/content`
    );
  }

  // ── Task Operations ──

  async listTasks(node: string): Promise<Record<string, unknown>[]> {
    return this.request<Record<string, unknown>[]>(
      "GET",
      `/nodes/${node}/tasks`
    );
  }

  async getTaskStatus(
    node: string,
    upid: string
  ): Promise<Record<string, unknown>> {
    return this.request<Record<string, unknown>>(
      "GET",
      `/nodes/${node}/tasks/${encodeURIComponent(upid)}/status`
    );
  }

  // ── Cluster Resources ──

  async getClusterResources(
    type?: string
  ): Promise<Record<string, unknown>[]> {
    const path = type
      ? `/cluster/resources?type=${type}`
      : "/cluster/resources";
    return this.request<Record<string, unknown>[]>("GET", path);
  }

  // ── SSH Command Execution ──

  async executeCommand(command: string): Promise<string> {
    // This executes via the Proxmox host's shell through the API
    // For more complex operations, we use SSH directly
    throw new Error(
      "Direct command execution should use SSH, not the API. Use the exec_command tool instead."
    );
  }
}
