terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.16.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "oci" {
  region           = var.region
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  private_key      = var.private_key != "" ? var.private_key : null
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

data "oci_core_images" "ubuntu_arm_images" {
  compartment_id           = var.compartment_id
  operating_system         = var.operating_system
  operating_system_version = var.operating_system_version
  shape                    = var.master_shape
  state                    = "AVAILABLE"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Imagem custom void-oci importada na tenancy do Rafael
data "oci_core_images" "void_oci_image" {
  compartment_id = var.compartment_id
  display_name   = var.void_oci_image_display_name
  state          = "AVAILABLE"
  sort_by        = "TIMECREATED"
  sort_order     = "DESC"
}

locals {
  # Imagem a usar: void-oci custom (default) ou Ubuntu (fallback)
  image_id = var.void_oci_image_display_name != "" ? data.oci_core_images.void_oci_image.images[0].id : data.oci_core_images.ubuntu_arm_images.images[0].id
}


resource "oci_core_vcn" "k3s_vcn" {
  compartment_id = var.compartment_id
  display_name   = var.vcn_display_name
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = var.vcn_dns_label
  is_ipv6enabled = true
}

resource "oci_core_internet_gateway" "k3s_igw" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.k3s_vcn.id
  display_name   = var.igw_display_name
  enabled        = true
}

# NOTE (22/ago): LPG/peering REMOVIDO — o cluster v3 é STANDALONE (2 masters
# + 2 workers só entre eles, sem contato com o cluster principal). O peering
# antigo ficou preso do lado remoto ("has already been connected") e travava
# o apply. Se um dia integrar com o cluster principal: desconectar o peering
# velho no lado remoto primeiro, depois re-adicionar o resource
# (var.delphus_lpg_id e a rota do peer abaixo).

resource "oci_core_default_route_table" "k3s_rt" {
  manage_default_resource_id = oci_core_vcn.k3s_vcn.default_route_table_id
  display_name               = var.route_table_display_name

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.k3s_igw.id
  }

  route_rules {
    destination       = "::/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.k3s_igw.id
  }
}

resource "oci_core_security_list" "k3s_seclist" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.k3s_vcn.id
  display_name   = var.security_list_display_name

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  egress_security_rules {
    destination = "::/0"
    protocol    = "all"
    description = "Allow all IPv6 egress traffic"
  }

  # Dynamic TCP ports from external sources (IPv4)
  dynamic "ingress_security_rules" {
    for_each = var.external_tcp_ports
    content {
      protocol = "6"
      source   = "0.0.0.0/0"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
      description = "TCP port ${ingress_security_rules.value} external access IPv4"
    }
  }

  # Dynamic TCP ports from external sources (IPv6)
  dynamic "ingress_security_rules" {
    for_each = var.external_tcp_ports
    content {
      protocol = "6"
      source   = "::/0"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
      description = "TCP port ${ingress_security_rules.value} external access IPv6"
    }
  }

  # Dynamic UDP ports from external sources (IPv4)
  dynamic "ingress_security_rules" {
    for_each = var.external_udp_ports
    content {
      protocol = "17"
      source   = "0.0.0.0/0"
      udp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
      description = "UDP port ${ingress_security_rules.value} external access IPv4"
    }
  }

  # Dynamic UDP ports from external sources (IPv6)
  dynamic "ingress_security_rules" {
    for_each = var.external_udp_ports
    content {
      protocol = "17"
      source   = "::/0"
      udp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
      description = "UDP port ${ingress_security_rules.value} external access IPv6"
    }
  }

  # VXLAN tunnel port 8472 UDP - required for Cilium VXLAN encapsulation (IPv4)
  ingress_security_rules {
    protocol = "17"
    source   = var.subnet_cidr
    udp_options {
      min = 8472
      max = 8472
    }
    description = "VXLAN encapsulation port 8472 UDP (IPv4)"
  }

  # VXLAN tunnel port 8472 UDP - required for Cilium VXLAN encapsulation (IPv6)
  ingress_security_rules {
    protocol = "17"
    source   = cidrsubnet(oci_core_vcn.k3s_vcn.ipv6cidr_blocks[0], 8, 0)
    udp_options {
      min = 8472
      max = 8472
    }
    description = "VXLAN encapsulation port 8472 UDP (IPv6)"
  }

  # All traffic allowed between K3s nodes in subnet (IPv4)
  ingress_security_rules {
    protocol    = "all"
    source      = var.subnet_cidr
    description = "Allow all TCP/UDP traffic between K3s nodes (IPv4)"
  }

  # All traffic from the peer VCN via peering
  ingress_security_rules {
    protocol    = "all"
    source      = var.delphus_vcn_cidr
    description = "Allow all traffic from peer VCN (peering)"
  }

  # All traffic allowed between K3s nodes in subnet (IPv6)
  ingress_security_rules {
    protocol    = "all"
    source      = cidrsubnet(oci_core_vcn.k3s_vcn.ipv6cidr_blocks[0], 8, 0)
    description = "Allow all TCP/UDP traffic between K3s nodes (IPv6)"
  }

  # Allow all traffic from K3s network ranges (IPv4)
  ingress_security_rules {
    protocol    = "all"
    source      = var.cluster_cidr
    description = "Allow all traffic from K3s pod network (IPv4)"
  }

  ingress_security_rules {
    protocol    = "all"
    source      = var.service_cidr
    description = "Allow all traffic from K3s service network (IPv4)"
  }

  # Allow all traffic from K3s network ranges (IPv6)
  ingress_security_rules {
    protocol    = "all"
    source      = var.cluster_cidr_ipv6
    description = "Allow all traffic from K3s pod network (IPv6)"
  }

  ingress_security_rules {
    protocol    = "all"
    source      = var.service_cidr_ipv6
    description = "Allow all traffic from K3s service network (IPv6)"
  }

  # ICMP - External access (IPv4)
  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"
    icmp_options {
      type = 8
      code = 0
    }
    description = "ICMP ping from external IPv4"
  }

  # ICMP - External access (IPv6)
  ingress_security_rules {
    protocol = "58"
    source   = "::/0"
    icmp_options {
      type = 128
      code = 0
    }
    description = "ICMPv6 ping from external IPv6"
  }

  # Cilium health endpoint port 4240 (TCP) between nodes
  ingress_security_rules {
    protocol = "6"
    source   = var.subnet_cidr
    tcp_options {
      min = 4240
      max = 4240
    }
    description = "Cilium health endpoint port 4240 (TCP) from nodes"
  }

  # ICMP - Internal subnet access (IPv4)
  ingress_security_rules {
    protocol = "1"
    source   = var.subnet_cidr
    icmp_options {
      type = 8
      code = 0
    }
    description = "ICMP ping between nodes IPv4"
  }

  dynamic "ingress_security_rules" {
    for_each = var.custom_ingress_rules
    content {
      protocol = ingress_security_rules.value.protocol
      source   = ingress_security_rules.value.source

      dynamic "tcp_options" {
        for_each = ingress_security_rules.value.protocol == "6" ? [1] : []
        content {
          min = ingress_security_rules.value.port_min
          max = ingress_security_rules.value.port_max
        }
      }

      dynamic "udp_options" {
        for_each = ingress_security_rules.value.protocol == "17" ? [1] : []
        content {
          min = ingress_security_rules.value.port_min
          max = ingress_security_rules.value.port_max
        }
      }
    }
  }
}

resource "oci_core_subnet" "k3s_subnet" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.k3s_vcn.id
  display_name   = var.subnet_display_name
  cidr_block     = var.subnet_cidr
  # Use the first /64 subnet from the VCN's assigned IPv6 range
  dns_label                  = var.subnet_dns_label
  security_list_ids          = [oci_core_security_list.k3s_seclist.id]
  route_table_id             = oci_core_vcn.k3s_vcn.default_route_table_id
  prohibit_public_ip_on_vnic = var.prohibit_public_ip_on_vnic
  ipv6cidr_block             = cidrsubnet(oci_core_vcn.k3s_vcn.ipv6cidr_blocks[0], 8, 0)
}

resource "oci_core_instance" "k3s_masters" {
  count               = var.master_count
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  compartment_id      = var.compartment_id
  display_name        = "${var.master_prefix}-${format("%02d", count.index + 1)}"
  shape               = var.master_shape

  dynamic "shape_config" {
    for_each = var.master_shape_config != null ? [var.master_shape_config] : []
    content {
      ocpus         = shape_config.value.ocpus
      memory_in_gbs = shape_config.value.memory_in_gbs
    }
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.k3s_subnet.id
    display_name     = "${var.master_prefix}-${format("%02d", count.index + 1)}-vnic"
    assign_public_ip = var.assign_public_ip
    hostname_label   = "${var.master_hostname_prefix}${format("%02d", count.index + 1)}"
    private_ip       = var.master_private_ips[count.index]
    assign_ipv6ip    = true
    # IPv6 address will be automatically assigned from subnet range
  }

  source_details {
    source_type             = "image"
    source_id               = local.image_id
    boot_volume_size_in_gbs = var.master_boot_volume_size
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.k3s_master_cloud_init[count.index])
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags
}

resource "oci_core_instance" "k3s_workers" {
  count               = var.worker_count
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  compartment_id      = var.compartment_id
  display_name        = "${var.worker_prefix}-${format("%02d", count.index + 1)}"
  shape               = var.worker_shape

  shape_config {
    ocpus         = var.worker_ocpus
    memory_in_gbs = var.worker_memory_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.k3s_subnet.id
    display_name     = "${var.worker_prefix}-${format("%02d", count.index + 1)}-vnic"
    assign_public_ip = var.assign_public_ip
    hostname_label   = "${var.worker_hostname_prefix}${format("%02d", count.index + 1)}"
    private_ip       = var.worker_private_ips[count.index]
    assign_ipv6ip    = true
    # IPv6 address will be automatically assigned from subnet range
  }

  source_details {
    source_type             = "image"
    source_id               = local.image_id
    boot_volume_size_in_gbs = var.worker_boot_volume_size
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.k3s_worker_cloud_init[count.index])
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags
}

# NOTE: buckets/group/policy CSI S3 removidos — o cluster principal já tem os
# buckets em uso. O v3 só adiciona NODES ao cluster.

locals {
  k3s_master_cloud_init = [
    for i in range(var.master_count) : templatefile("${path.module}/scripts/master1.sh", {
      k3s_token         = var.k3s_join_token
      server_url        = var.k3s_server_url
      node_name         = "${var.master_prefix}-${format("%02d", i + 1)}"
      cluster_cidr      = var.cluster_cidr
      service_cidr      = var.service_cidr
      cluster_cidr_ipv6 = var.cluster_cidr_ipv6
      service_cidr_ipv6 = var.service_cidr_ipv6
      k3s_join_mode     = var.k3s_join_mode
    })
  ]

  k3s_worker_cloud_init = [
    for i in range(var.worker_count) : templatefile("${path.module}/scripts/worker${i + 1}.sh", {
      k3s_token     = var.k3s_join_token
      server_url    = var.k3s_server_url
      node_name     = "${var.worker_prefix}-${format("%02d", i + 1)}"
      k3s_join_mode = var.k3s_join_mode
    })
  ]
}

output "k3s_master_public_ips" {
  description = "Public IP addresses of K3s masters"
  value = {
    for i, instance in oci_core_instance.k3s_masters :
    "${var.master_prefix}-${format("%02d", i + 1)}" => instance.public_ip
  }
}

output "k3s_master_private_ips" {
  description = "Private IP addresses of K3s masters"
  value = {
    for i, instance in oci_core_instance.k3s_masters :
    "${var.master_prefix}-${format("%02d", i + 1)}" => instance.private_ip
  }
}

output "k3s_master_private_ipv6s" {
  description = "Private IPv6 addresses of K3s masters"
  value = {
    for i in range(var.master_count) :
    "${var.master_prefix}-${format("%02d", i + 1)}" => var.master_private_ipv6_addresses[i]
  }
}

output "k3s_worker_public_ips" {
  description = "Public IP addresses of K3s workers"
  value = {
    for i, instance in oci_core_instance.k3s_workers :
    "${var.worker_prefix}-${format("%02d", i + 1)}" => instance.public_ip
  }
}

output "k3s_worker_private_ips" {
  description = "Private IP addresses of K3s workers"
  value = {
    for i, instance in oci_core_instance.k3s_workers :
    "${var.worker_prefix}-${format("%02d", i + 1)}" => instance.private_ip
  }
}

output "k3s_worker_private_ipv6s" {
  description = "Private IPv6 addresses of K3s workers"
  value = {
    for i in range(var.worker_count) :
    "${var.worker_prefix}-${format("%02d", i + 1)}" => var.worker_private_ipv6_addresses[i]
  }
}

output "ssh_commands" {
  description = "SSH commands to connect to all nodes"
  value = merge(
    {
      for i, instance in oci_core_instance.k3s_masters :
      "${var.master_prefix}-${format("%02d", i + 1)}" => "ssh ${var.system_username}@${instance.public_ip}"
    },
    {
      for i, instance in oci_core_instance.k3s_workers :
      "${var.worker_prefix}-${format("%02d", i + 1)}" => "ssh ${var.system_username}@${instance.public_ip}"
    }
  )
}

output "cluster_info" {
  description = "K3s cluster configuration summary"
  value = {
    network = {
      vcn_cidr          = var.vcn_cidr
      subnet_cidr       = var.subnet_cidr
      cluster_cidr      = var.cluster_cidr
      service_cidr      = var.service_cidr
      cluster_cidr_ipv6 = var.cluster_cidr_ipv6
      service_cidr_ipv6 = var.service_cidr_ipv6
    }
    masters = {
      count         = var.master_count
      shape         = var.master_shape
      private_ips   = var.master_private_ips
      private_ipv6s = var.master_private_ipv6_addresses
    }
    workers = {
      count         = var.worker_count
      shape         = var.worker_shape
      private_ips   = var.worker_private_ips
      private_ipv6s = var.worker_private_ipv6_addresses
    }
    system = {
      timezone = var.timezone
      domain   = var.k3s_cluster_domain
      username = var.system_username
    }
    k3s = {
      version    = var.k3s_version
      server_url = var.k3s_server_url
    }
  }
}
