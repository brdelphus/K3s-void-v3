variable "region" {
  description = "OCI region"
  type        = string
  default     = "sa-saopaulo-1"
}

variable "tenancy_ocid" {
  description = "OCI tenancy OCID"
  type        = string
}

variable "user_ocid" {
  description = "OCI user OCID"
  type        = string
}

variable "fingerprint" {
  description = "OCI API key fingerprint"
  type        = string
}

variable "private_key_path" {
  description = "Path to OCI private key file"
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "private_key" {
  description = "OCI private key content"
  type        = string
  default     = ""
  sensitive   = true
}

variable "compartment_id" {
  description = "OCI compartment OCID"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for system user"
  type        = string
}

variable "system_username" {
  description = "System username to create on instances"
  type        = string
  default     = "void"
}

variable "operating_system" {
  description = "Operating system for instances"
  type        = string
  default     = "Canonical Ubuntu"
}

variable "operating_system_version" {
  description = "Operating system version"
  type        = string
  default     = "22.04"
}

variable "master_shape" {
  description = "Shape for master nodes"
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "worker_shape" {
  description = "Shape for worker nodes"
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "master_shape_config" {
  description = "Shape config for masters"
  type = object({
    ocpus         = number
    memory_in_gbs = number
  })
  default = {
    ocpus         = 1
    memory_in_gbs = 6
  }
}

variable "worker_ocpus" {
  description = "OCPUs for worker nodes"
  type        = number
  default     = 1
}

variable "worker_memory_gb" {
  description = "Memory in GB for worker nodes"
  type        = number
  default     = 6
}

variable "master_count" {
  description = "Number of master nodes"
  type        = number
  default     = 1
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}

variable "master_prefix" {
  description = "Prefix for master node names"
  type        = string
  default     = "k3s-master"
}

variable "worker_prefix" {
  description = "Prefix for worker node names"
  type        = string
  default     = "k3s-worker"
}

variable "master_hostname_prefix" {
  description = "Hostname prefix for master nodes"
  type        = string
  default     = "k3smaster"
}

variable "worker_hostname_prefix" {
  description = "Hostname prefix for worker nodes"
  type        = string
  default     = "k3sworker"
}

variable "master_boot_volume_size" {
  description = "Boot volume size in GB for master nodes"
  type        = number
  default     = 50
}

variable "worker_boot_volume_size" {
  description = "Boot volume size in GB for worker nodes"
  type        = number
  default     = 50
}

variable "availability_domain_index" {
  description = "Index of availability domain to use"
  type        = number
  default     = 0
}

variable "assign_public_ip" {
  description = "Assign public IP to instances"
  type        = bool
  default     = true
}

variable "master_external_ipv4_addresses" {
  description = "External IPv4 addresses for K3s masters"
  type        = list(string)
}

variable "master_external_ipv6_addresses" {
  description = "External IPv6 addresses for K3s masters"
  type        = list(string)
}

variable "worker_external_ipv4_addresses" {
  description = "External IPv4 addresses for K3s workers"
  type        = list(string)
}

variable "worker_external_ipv6_addresses" {
  description = "External IPv6 addresses for K3s workers"
  type        = list(string)
}


variable "master_private_ips" {
  description = "Private IP addresses for K3s masters"
  type        = list(string)
}

variable "worker_private_ips" {
  description = "Private IP addresses for K3s workers"
  type        = list(string)
}

variable "master_private_ipv6_addresses" {
  description = "Static private IPv6 addresses for K3s masters (used in netplan)"
  type        = list(string)
}

variable "worker_private_ipv6_addresses" {
  description = "Static private IPv6 addresses for K3s workers (used in netplan)"
  type        = list(string)
}

# IPv6 addresses will be automatically assigned by OCI DHCP + static configuration via netplan


variable "vcn_cidr" {
  description = "CIDR block for VCN"
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR block for subnet"
  type        = string
}

# IPv6 subnet CIDR will be automatically assigned by OCI

variable "cluster_cidr" {
  description = "CIDR block for K3s cluster pods"
  type        = string
  default     = "10.42.0.0/16"
}

variable "service_cidr" {
  description = "CIDR block for K3s services"
  type        = string
  default     = "10.43.0.0/16"
}

variable "cluster_cidr_ipv6" {
  description = "IPv6 CIDR block for K3s cluster pods"
  type        = string
  default     = "2001:cafe:42::0/56"
}

variable "service_cidr_ipv6" {
  description = "IPv6 CIDR block for K3s services"
  type        = string
  default     = "2001:cafe:43::0/112"
}

variable "vcn_display_name" {
  description = "Display name for VCN"
  type        = string
  default     = "k3s-cluster-vcn"
}

variable "vcn_dns_label" {
  description = "DNS label for VCN"
  type        = string
  default     = "k3scluster"
}

variable "subnet_display_name" {
  description = "Display name for subnet"
  type        = string
  default     = "k3s-subnet"
}

variable "subnet_dns_label" {
  description = "DNS label for subnet"
  type        = string
  default     = "k3ssubnet"
}

variable "igw_display_name" {
  description = "Display name for internet gateway"
  type        = string
  default     = "k3s-igw"
}

variable "route_table_display_name" {
  description = "Display name for route table"
  type        = string
  default     = "k3s-route-table"
}

variable "security_list_display_name" {
  description = "Display name for security list"
  type        = string
  default     = "k3s-security-list"
}

variable "prohibit_public_ip_on_vnic" {
  description = "Prohibit public IP on VNIC"
  type        = bool
  default     = false
}

variable "ssh_allowed_cidr" {
  description = "CIDR block allowed for SSH access"
  type        = string
  default     = "0.0.0.0/0"
}

variable "k8s_api_allowed_cidr" {
  description = "CIDR block allowed for Kubernetes API access"
  type        = string
  default     = "0.0.0.0/0"
}

variable "icmp_allowed_cidr" {
  description = "CIDR block allowed for ICMP"
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_port" {
  description = "SSH port"
  type        = number
  default     = 22
}

variable "k8s_api_port" {
  description = "Kubernetes API server port"
  type        = number
  default     = 6443
}

variable "flannel_port" {
  description = "Flannel VXLAN port"
  type        = number
  default     = 8472
}

variable "kubelet_port" {
  description = "Kubelet API port"
  type        = number
  default     = 10250
}

variable "etcd_client_port" {
  description = "etcd client communication port"
  type        = number
  default     = 2379
}

variable "etcd_peer_port" {
  description = "etcd peer communication port"
  type        = number
  default     = 2380
}

variable "external_tcp_ports" {
  description = "TCP ports allowed from external sources (0.0.0.0/0)"
  type        = list(number)
  default     = [22, 25, 53, 80, 443, 465, 587, 993, 995, 6443, 30486, 30745, 30802]
}

variable "external_udp_ports" {
  description = "UDP ports allowed from external sources (0.0.0.0/0)"
  type        = list(number)
  default     = [53, 30486]
}

variable "custom_ingress_rules" {
  description = "Custom ingress security rules"
  type = list(object({
    protocol = string
    source   = string
    port_min = number
    port_max = number
  }))
  default = []
}

variable "k3s_version" {
  description = "K3s version to install"
  type        = string
  default     = ""
}

# --- K3s-void-v3: join ---
variable "k3s_join_token" {
  description = "K3s join token — vem do ambiente (.env), NUNCA versionar"
  type        = string
  sensitive   = true
}

variable "k3s_join_mode" {
  description = "join (default, registra no cluster) ou test (baixa/instala o k3s mas NÃO contata o master — validação de timing em ciclos destroy/apply)"
  type        = string
  default     = "join"
}

variable "k3s_server_url" {
  description = "URL do master K3s para join (ex: https://10.0.0.1:6443)"
  type        = string
}

# --- VCN peering (opcional) ---
variable "delphus_vcn_cidr" {
  description = "CIDR da VCN remota para peering"
  type        = string
}

variable "delphus_lpg_id" {
  description = "OCID do LPG da VCN remota para conectar o peering"
  type        = string
}

variable "lpg_display_name" {
  description = "Display name do LPG local"
  type        = string
  default     = "lpg-to-peer"
}

# --- Imagem void-oci ---
variable "void_oci_image_display_name" {
  description = "Display name da imagem custom void-oci importada na sua tenancy (vazio = usa Ubuntu)"
  type        = string
  default     = "void-oci-aarch64-20260820"
}

variable "k3s_cluster_domain" {
  description = "Domain name for K3s cluster"
  type        = string
  default     = "k3s.example.org"
}

variable "k3s_token_length" {
  description = "Length of K3s cluster token (minimum 16 characters)"
  type        = number
  default     = 32

  validation {
    condition     = var.k3s_token_length >= 16 && var.k3s_token_length <= 128
    error_message = "K3s token length must be between 16 and 128 characters."
  }
}

variable "timezone" {
  description = "Timezone for all instances"
  type        = string
  default     = "America/Sao_Paulo"
}

variable "freeform_tags" {
  description = "Freeform tags to apply to all resources"
  type        = map(string)
  default = {
    "Environment" = "k3s-cluster"
    "CreatedBy"   = "terraform"
    "Project"     = "k3s-oci-free-tier"
  }
}

variable "defined_tags" {
  description = "Defined tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "psa_exempted_namespaces" {
  description = "List of namespaces exempted from Pod Security Standards enforcement"
  type        = list(string)
  default = [
    "kube-system",
    "ingress-nginx",
    "monitoring",
    "cert-manager",
    "nextcloud",
    "metallb",
    "mail",
    "dns"
  ]
}
