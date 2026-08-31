# K3s Cluster on Oracle Cloud Infrastructure (OCI)

A production-ready K3s Kubernetes cluster deployment on Oracle Cloud Infrastructure with Flannel CNI, CIS hardening, and dual-stack networking support.

## 🚀 Features

- **K3s Lightweight Kubernetes** - Fast, certified Kubernetes distribution
- **Oracle Cloud Infrastructure** - ARM-based VM.Standard.A1.Flex instances
- **Flannel CNI** - Lightweight networking with VXLAN backend
- **CIS Hardening** - Security compliance with Pod Security Standards
- **Dual-Stack Networking** - IPv4 and IPv6 support
- **Oracle Cloud Firewall Integration** - Automatic firewall management
- **Automated Deployment** - One-command cluster deployment and teardown

## 📋 Prerequisites

### Required Tools
- **Terraform** >= 1.0 — `sudo xbps-install -S terraform` (Void Linux) or download from [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install)
- **OCI CLI** (`oci`) — `pip3 install --user oci-cli` or the official installer: [docs.oracle.com OCI CLI install](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm)
- **jq** — `sudo xbps-install -S jq` (used by `deploy-enhanced.sh`)
- **SSH client** and **git**

The OCI **provider** binary needs no manual install: `terraform init` downloads the `oracle/oci` provider into `.terraform/providers/` (gitignored, never committed).

### Oracle Cloud Infrastructure Setup
1. **OCI account** with compute quota for `VM.Standard.A1.Flex` (ARM, Always Free eligible)
2. **VCN and Subnet** — created by this module; optionally peer with another VCN (see `delphus_vcn_cidr` / `delphus_lpg_id` in `terraform.tfvars`)
3. **API key** for Terraform — see [Credentials](#credentials)
4. **Void Linux image** imported into your tenancy — see [Void Linux image](#void-linux-image)

## 🔑 Credentials

All OCI credentials are read from `env-vars.txt` (never committed). Create it from the example:

```bash
cp env-vars.txt.example env-vars.txt
```

### OCI API key (for Terraform)
1. In the OCI Console: user menu (top-right) → **My profile** → **API keys** → **Add API key**
2. Either generate a new key pair (download the private key) or upload your own public key
3. The console then shows the **fingerprint** — copy it
4. Fill in the fields below

Where each value lives in the console:
- `TF_VAR_tenancy_ocid` — Console → Tenancy details (OCID)
- `TF_VAR_user_ocid` — Console → My profile (OCID)
- `TF_VAR_fingerprint` — My profile → API keys (the one you just added)
- `TF_VAR_private_key_path` — path to the downloaded private key, e.g. `$HOME/.oci/oci_api_key.pem`
- `TF_VAR_region` — your region, e.g. `sa-saopaulo-1`
- `TF_VAR_compartment_id` — Console → Identity → Compartments (OCID)

### SSH key (node access)
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
```

### K3s join token
```bash
export TF_VAR_k3s_join_token="$(openssl rand -base64 24)"
```
The same token is used by the seed master and by every node that joins it.

### Full env-vars.txt example
```bash
export TF_VAR_tenancy_ocid="ocid1.tenancy.oc1..your-tenancy-id"
export TF_VAR_user_ocid="ocid1.user.oc1..your-user-id"
export TF_VAR_fingerprint="ab:cd:ef:12:34:56:78:90:ab:cd:ef:12:34:56:78:90"
export TF_VAR_private_key_path="$HOME/.oci/oci_api_key.pem"
export TF_VAR_region="sa-saopaulo-1"
export TF_VAR_compartment_id="ocid1.compartment.oc1..your-compartment-id"
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
export TF_VAR_k3s_join_token="$(openssl rand -base64 24)"
```

## 🖼️ Void Linux image

This module boots **Void Linux** (ARM64) instances. The image is built and maintained by the [`void-oci`](https://github.com/brdelphus/void-oci) project — a reproducible Void Linux QCOW2/OCI image with cloud-init, OpenRC and Oracle cloud agent integration.

To use a custom build:
1. Build the image with `void-oci` (e.g. `./build.sh aarch64`)
2. Upload the QCOW2 to OCI Object Storage and import it as a custom image
3. Add ARM shape compatibility for the imported image:
   `oci compute image-shape-compatibility-entry add --image-id <ocid> --shape-name VM.Standard.A1.Flex`
4. Set `void_oci_image_display_name` in `terraform.tfvars` to the imported image's display name (e.g. `void-oci-aarch64-20260822`)

If `void_oci_image_display_name` is left empty, the module falls back to a stock Ubuntu image.

## 🔧 Configuration

### 1. Environment Variables
Copy and configure your OCI credentials (see [Credentials](#credentials) for how to generate each one):
```bash
cp env-vars.txt.example env-vars.txt
# Edit env-vars.txt with your actual OCI credentials, then:
source env-vars.txt
```

Required variables:
- `TF_VAR_tenancy_ocid` - Your OCI tenancy OCID
- `TF_VAR_user_ocid` - Your OCI user OCID
- `TF_VAR_private_key_path` - Path to your OCI private key
- `TF_VAR_fingerprint` - Your OCI key fingerprint
- `TF_VAR_compartment_id` - Target compartment OCID
- `TF_VAR_ssh_public_key` - SSH public key for instance access
- `TF_VAR_k3s_join_token` - Secure token for joining the K3s cluster (never commit)

### 2. Terraform Variables
Copy and configure cluster settings:
```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your cluster configuration
```

Key variables:
- `master_private_ips` / `worker_private_ips` - Static private IPs for the nodes
- `master_external_ipv4_addresses` - External IP addresses for master nodes
- `worker_external_ipv4_addresses` - External IP addresses for worker nodes
- `k3s_server_url` - URL of the seed master that nodes join
- `k3s_join_mode` - `join` (register in cluster) or `test` (install without contacting the master)
- `void_oci_image_display_name` - Void Linux OCI image imported into your tenancy
- `system_username` - Username for SSH access

## 🚀 Deployment

### Quick Start
```bash
# 1. Source environment variables
source env-vars.txt

# 2. Run deployment script
./deploy-enhanced.sh
```

### Manual Deployment
```bash
# 1. Source environment variables
source env-vars.txt

# 2. Initialize Terraform backend
terraform init

# 3. Plan deployment
terraform plan

# 4. Deploy infrastructure
terraform apply
```

## 🏗️ Architecture

### Cluster Components
- **2 Master Nodes** - K3s servers with embedded etcd (HA: seed + join)
- **2 Worker Nodes** - K3s agents with workload scheduling
- **Flannel CNI** - Container networking with VXLAN backend
- **CIS Hardening** - Security policies and Pod Security Standards

### Network Configuration
- **Pod CIDR:** `10.42.0.0/16` (IPv4), `2001:cafe:42::0/48` (IPv6)
  - Each node gets a `/64` subnet carved from the `/48` cluster CIDR
- **Service CIDR:** `10.43.0.0/16` (IPv4), `2001:cafe:43::0/112` (IPv6)
- **CNI:** Flannel with VXLAN encapsulation

### Security Features
- **Firewall Management** - Oracle Cloud iptables rules flushed, K3s/Flannel manages networking
- **Pod Security Standards** - Enforced security policies
- **CIS Compliance** - Hardened kernel parameters and security settings
- **Fail2ban** - SSH brute-force protection

## 📁 Project Structure

```
k3s-void-v3/
├── main.tf                    # Main Terraform configuration
├── variables.tf               # Terraform variables
├── terraform.tfvars.example  # Example cluster configuration
├── env-vars.txt.example      # Example environment variables
├── deploy-enhanced.sh         # Deployment automation script
├── scripts/
│   ├── master1.sh            # Master node initialization
│   ├── worker1.sh            # Worker node 1 initialization
│   ├── worker2.sh            # Worker node 2 initialization
│   └── worker3.sh            # Worker node 3 initialization
├── upgrade/
│   ├── upgrade.sh            # Adapted upgrade script (Void, no systemd)
│   ├── Dockerfile            # k3s-upgrade-void image build
│   ├── suc-manifest.yaml     # system-upgrade-controller manifest
│   ├── plans-void.yaml       # Example server/agent upgrade plans
│   └── README.md             # Upgrade workflow docs
└── README.md                 # This file
```

## 🔐 Security Considerations

### Firewall Management
The deployment automatically:
1. **Flushes Oracle Cloud default iptables rules** that block inter-node communication
2. **Removes netfilter-persistent package** to prevent rule restoration
3. **Lets K3s and Flannel manage iptables** completely

### Pod Security Standards
- **Restricted policy** enforced for most namespaces
- **Privileged exemptions** for system namespaces
- **CIS hardening** with secure kernel parameters

### Access Control
- **SSH key-based authentication** only
- **Fail2ban protection** against brute-force attacks
- **Network policies** available through Kubernetes NetworkPolicy API

## 🛠️ Troubleshooting

### Common Issues

#### 1. Firewall Connectivity Problems
**Problem:** Pods can't connect to services or other nodes
**Solution:** Ensure Oracle Cloud default firewall rules are flushed:
```bash
# On each node:
sudo iptables -F
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT
```

#### 2. Flannel Networking Issues
**Problem:** Flannel pods in CrashLoopBackOff or not ready
**Solution:** Check Flannel pods and ensure VXLAN backend is configured:
```bash
kubectl get pods -n kube-system -l app=flannel
# Check logs: kubectl logs -n kube-system -l app=flannel
```

#### 3. Terraform State Issues
**Problem:** Terraform state errors
**Solution:** The state is stored locally (`terraform.tfstate`). Ensure the OCI
credentials are correct and your API key has the required permissions:
```bash
oci iam compartment list --compartment-id $TF_VAR_compartment_id
```

### Verification Commands
```bash
# Check cluster status
kubectl get nodes -o wide

# Check Flannel status
kubectl get pods -n kube-system -l app=flannel

# Check networking
kubectl get daemonsets -n kube-system

# Check pod connectivity
kubectl run test-pod --image=busybox --rm -it -- sh
```

## 🔄 Maintenance

### Cluster Updates
Automated via the [system-upgrade-controller](upgrade/) — no manual steps per node. On a new stable K3s release:

```bash
# 1. Build & push the upgrade image (amd64 + arm64)
gh workflow run build-upgrade-image.yml -f version=v<NEW_VERSION>-k3s1

# 2. Apply the upgrade plans (see upgrade/plans-void.yaml)
kubectl apply -f upgrade/plans-void.yaml
```

The controller cordons the control planes and drains workers one by one, rolling the cluster to the target version. See [`upgrade/README.md`](upgrade/) for the full workflow, gotchas and rollback notes.

### Backup and Recovery
```bash
# Etcd snapshot (HA embedded etcd) — run on a server node
sudo k3s etcd-snapshot save --dir /var/lib/rancher/k3s/server/db/snapshots/

# Full backup (OpenRC on Void)
sudo rc-service k3s stop
sudo tar czf k3s-backup.tar.gz /var/lib/rancher/k3s/
sudo rc-service k3s start

# Restore from backup
sudo rc-service k3s stop
sudo rm -rf /var/lib/rancher/k3s/
sudo tar xzf k3s-backup.tar.gz -C /
sudo rc-service k3s start
```

## 🗑️ Cleanup

### Destroy Cluster
```bash
# Using deployment script
./deploy-enhanced.sh
# Select option: destroy

# Manual cleanup
source env-vars.txt
terraform destroy
```

## 📚 References

- [K3s Documentation](https://docs.k3s.io/)
- [K3s Automated Upgrades](https://docs.k3s.io/upgrades/automated)
- [Flannel Documentation](https://github.com/flannel-io/flannel)
- [Oracle Cloud Infrastructure Documentation](https://docs.oracle.com/en-us/iaas/)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## ⚠️ Disclaimer

This project creates real cloud infrastructure that will incur costs. Always review and understand the resources being created before deployment. Monitor your Oracle Cloud billing to avoid unexpected charges.
