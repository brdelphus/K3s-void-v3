#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_status() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
print_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"; }
print_warning() { printf "${YELLOW}[WARNING]${NC} %s\n" "$1"; }
print_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }
print_step() { printf "${CYAN}[STEP]${NC} %s\n" "$1"; }

load_environment_variables() {
    print_step "Loading environment variables..."
    
    if [ -f "env-vars.txt" ]; then
        print_status "Found env-vars.txt, loading variables..."
        source env-vars.txt
        print_success "Environment variables loaded!"
    else
        print_warning "env-vars.txt file not found!"
        print_warning "Make sure TF_VAR_* variables are defined in the environment."
        
        # Check if essential variables are set
        if [ -z "$TF_VAR_tenancy_ocid" ] || [ -z "$TF_VAR_user_ocid" ] || [ -z "$TF_VAR_fingerprint" ]; then
            print_error "Essential variables not found!"
            print_error "Run: source env-vars.txt or manually define TF_VAR_* variables"
            exit 1
        fi
    fi
}

validate_requirements() {
    print_step "Validating prerequisites..."
    
    local missing_tools=()
    
    if ! command -v terraform > /dev/null 2>&1; then
        missing_tools+=("terraform")
    fi
    
    if ! command -v jq > /dev/null 2>&1; then
        missing_tools+=("jq")
    fi
    
    if ! command -v curl > /dev/null 2>&1; then
        missing_tools+=("curl")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_error "Missing tools: ${missing_tools[*]}"
        exit 1
    fi
    
    print_success "Prerequisites validated!"
}

validate_oci_config() {
    print_step "Validating OCI configuration..."
    
    # Check environment variables instead of terraform.tfvars
    if [ -z "$TF_VAR_tenancy_ocid" ] || [ -z "$TF_VAR_user_ocid" ] || [ -z "$TF_VAR_fingerprint" ]; then
        print_error "OCI environment variables not configured!"
        print_error "Make sure to run: source env-vars.txt"
        exit 1
    fi
    
    if [[ "$TF_VAR_tenancy_ocid" == *"xxxxxxxx"* ]] || [[ "$TF_VAR_user_ocid" == *"xxxxxxxx"* ]] || [[ "$TF_VAR_fingerprint" == *"xx:xx"* ]]; then
        print_error "OCI credentials contain default values! Update env-vars.txt"
        exit 1
    fi
    
    # Check private key file
    if [ -n "$TF_VAR_private_key_path" ] && [ "$TF_VAR_private_key_path" != "" ]; then
        local private_key_path="${TF_VAR_private_key_path/#\~/$HOME}"
        if [ ! -f "$private_key_path" ]; then
            print_error "Private key not found: $private_key_path"
            exit 1
        fi
    fi
    
    print_success "OCI configuration validated!"
}

test_oci_connection() {
    print_step "Testing OCI connectivity..."

    # Initialize terraform first
    print_status "Initializing Terraform..."
    if terraform init > /dev/null 2>&1; then
        print_status "Terraform initialized successfully"
    else
        print_error "Terraform initialization failed!"
        terraform init
        exit 1
    fi

    # Now validate syntax
    if terraform validate > /dev/null 2>&1; then
        print_success "Terraform syntax validated!"
    else
        print_error "Terraform syntax error!"
        terraform validate
        exit 1
    fi
}

validate_always_free_limits() {
    print_step "Validating Always Free limits..."
    
    local master_count=$(grep '^master_count' terraform.tfvars | grep -o '[0-9]*')
    local worker_count=$(grep '^worker_count' terraform.tfvars | grep -o '[0-9]*')
    local worker_ocpus=$(grep '^worker_ocpus' terraform.tfvars | grep -o '[0-9]*')
    local worker_memory=$(grep '^worker_memory_gb' terraform.tfvars | grep -o '[0-9]*')
    
    if [ "$master_count" -gt 2 ]; then
        print_error "Master count ($master_count) exceeds Always Free limit (max: 2)"
        exit 1
    fi
    
    local total_worker_ocpus=$((worker_count * worker_ocpus))
    if [ "$total_worker_ocpus" -gt 4 ]; then
        print_error "Total worker OCPUs ($total_worker_ocpus) exceeds Always Free limit (max: 4)"
        exit 1
    fi
    
    local total_worker_memory=$((worker_count * worker_memory))
    if [ "$total_worker_memory" -gt 24 ]; then
        print_error "Total worker memory ($total_worker_memory GB) exceeds Always Free limit (max: 24 GB)"
        exit 1
    fi
    
    print_success "Limites Always Free respeitados!"
}

deploy_infrastructure() {
    print_step "Planning deployment..."
    terraform plan -out=tfplan

    print_step "Executing deployment..."
    if terraform apply tfplan; then
        print_success "Infrastructure deployed successfully!"
        rm -f tfplan
        return 0
    else
        print_error "Deploy failed! Check errors above."
        rm -f tfplan
        return 1
    fi
}

# External IPs are now detected automatically by cloud-init scripts
# No need for post-deploy IP updates to terraform.tfvars
display_cluster_info() {
    print_step "Displaying cluster information..."

    if ! terraform output k3s_master_public_ips > /dev/null 2>&1; then
        print_error "Outputs not found. Deploy may have failed."
        return 1
    fi

    local master_ips=($(terraform output -json k3s_master_public_ips | jq -r '.[]'))
    local worker_ips=($(terraform output -json k3s_worker_public_ips | jq -r '.[]'))
    local master_private_ips=($(terraform output -json k3s_master_private_ips | jq -r '.[]'))
    local worker_private_ips=($(terraform output -json k3s_worker_private_ips | jq -r '.[]'))

    if [ ${#master_ips[@]} -eq 0 ] || [ ${#worker_ips[@]} -eq 0 ]; then
        print_error "Could not obtain IPs from terraform output"
        return 1
    fi

    echo ""
    print_success "Master Nodes:"
    for i in "${!master_ips[@]}"; do
        echo "  Master $((i+1)): Public=${master_ips[$i]}, Private=${master_private_ips[$i]}"
    done

    echo ""
    print_success "Worker Nodes:"
    for i in "${!worker_ips[@]}"; do
        echo "  Worker $((i+1)): Public=${worker_ips[$i]}, Private=${worker_private_ips[$i]}"
    done

    echo ""
}

health_check() {
    print_step "Executando health check..."
    
    local master_ips=($(terraform output -json k3s_master_public_ips | jq -r '.[]'))
    local worker_ips=($(terraform output -json k3s_worker_public_ips | jq -r '.[]'))
    
    print_status "Testando conectividade SSH..."
    local ssh_accessible=0
    local total_instances=$((${#master_ips[@]} + ${#worker_ips[@]}))
    
    for ip in "${master_ips[@]}" "${worker_ips[@]}"; do
        if timeout 10 nc -z "$ip" 22 2>/dev/null; then
            print_success "SSH accessible: $ip"
            ((ssh_accessible++))
        else
            print_warning "SSH not accessible: $ip (initializing...)"
        fi
    done
    
    print_status "SSH Status: $ssh_accessible/$total_instances instances accessible"
}

show_post_deploy_instructions() {
    print_step "Post-deploy instructions"
    
    local master_ip=$(terraform output -json k3s_master_public_ips | jq -r '.["k3s-master-01"]')
    
    echo ""
    print_success "DEPLOY COMPLETED!"
    echo ""
    print_status "NEXT STEPS:"
    print_status "1. Wait 5-10 minutes for complete initialization"
    local ssh_user=$(grep -E '^[[:space:]]*system_username' terraform.tfvars 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')
    ssh_user=${ssh_user:-void}
    print_status "2. Conecte ao cluster: ssh ${ssh_user}@${master_ip}"
    print_status "3. Verifique cluster: kubectl get nodes -o wide"
    print_status "4. Verifique pods: kubectl get pods -A"
    print_status "5. Logs de setup: tail -f /var/log/k3s-setup.log"
}

show_menu() {
    echo ""
    print_step "Choose an option:"
    echo ""
    echo "1) Complete deploy (recommended)"
    echo "2) Initial deploy only"
    echo "3) Health check"
    echo "4) Show outputs"
    echo "5) Destroy infrastructure"
    echo "0) Exit"
    echo ""
    printf "Option: "
}

deploy_initial() {
    print_step "Initial deploy (without IP update)"
    deploy_infrastructure
    show_post_deploy_instructions
}

deploy_complete() {
    print_step "Complete deploy - External IPs detected automatically"

    deploy_infrastructure

    print_status "Waiting for cluster stabilization (30 seconds)..."
    sleep 30

    print_step "Displaying deployed cluster information..."
    if display_cluster_info; then
        print_success "Deploy completed successfully!"
        health_check
        show_post_deploy_instructions
    else
        print_error "Could not retrieve cluster information."
        print_status "Cluster may still be initializing. Check terraform outputs manually."
        show_post_deploy_instructions
    fi
}

show_outputs() {
    print_step "Outputs do Terraform:"
    echo ""
    terraform output
}

destroy_infrastructure() {
    print_warning "INFRASTRUCTURE DESTRUCTION"
    print_error "This operation is IRREVERSIBLE!"
    echo ""
    printf "Are you sure? Type 'DESTROY' to confirm: "
    read -r confirmation

    if [ "$confirmation" = "DESTROY" ]; then
        print_step "Destruindo infraestrutura..."

        # Just get the current IP addresses from terraform.tfvars since they're already set correctly
        local master_ipv4_addrs=""
        local worker_ipv4_addrs=""

        if [ -f terraform.tfvars ]; then
            print_status "Usando IPs do terraform.tfvars..."

            # Extract master IPs from terraform.tfvars
            master_ipv4_addrs=$(grep -A 10 "^master_external_ipv4_addresses" terraform.tfvars | grep '"[0-9]' | sed 's/.*"\([0-9.]*\)".*/\1/' | tr '\n' ',' | sed 's/,$//')

            # Extract worker IPs from terraform.tfvars
            worker_ipv4_addrs=$(grep -A 10 "^worker_external_ipv4_addresses" terraform.tfvars | grep '"[0-9]' | sed 's/.*"\([0-9.]*\)".*/\1/' | tr '\n' ',' | sed 's/,$//')

            print_status "Found master IPs: $master_ipv4_addrs"
            print_status "Found worker IPs: $worker_ipv4_addrs"
        fi

        # Build terraform destroy command with proper variable formatting
        print_status "Executando terraform destroy..."

        # Build master IP array
        local master_array=""
        if [ -n "$master_ipv4_addrs" ]; then
            IFS=',' read -ra MASTER_IPS <<< "$master_ipv4_addrs"
            for ip in "${MASTER_IPS[@]}"; do
                if [ -n "$master_array" ]; then
                    master_array="$master_array,\"$ip\""
                else
                    master_array="\"$ip\""
                fi
            done
        else
            master_array="\"0.0.0.0\""
        fi

        # Build worker IP array
        local worker_array=""
        if [ -n "$worker_ipv4_addrs" ]; then
            IFS=',' read -ra WORKER_IPS <<< "$worker_ipv4_addrs"
            for ip in "${WORKER_IPS[@]}"; do
                if [ -n "$worker_array" ]; then
                    worker_array="$worker_array,\"$ip\""
                else
                    worker_array="\"$ip\""
                fi
            done
        else
            worker_array="\"0.0.0.0\",\"0.0.0.0\",\"0.0.0.0\""
        fi

        # Build IPv6 arrays to match the counts
        local master_ipv6_array="\"::1\""
        local worker_ipv6_array="\"::1\",\"::1\",\"::1\""

        # Execute terraform destroy with proper variable formatting
        terraform destroy -auto-approve \
            -var-file="terraform.tfvars" \
            -var="master_external_ipv4_addresses=[$master_array]" \
            -var="worker_external_ipv4_addresses=[$worker_array]" \
            -var="master_external_ipv6_addresses=[$master_ipv6_array]" \
            -var="worker_external_ipv6_addresses=[$worker_ipv6_array]"

        if [ $? -eq 0 ]; then
            print_success "Infrastructure destroyed!"
        else
            print_error "Error during destruction!"
            return 1
        fi
    else
        print_status "Operation cancelled."
    fi
}

main() {
    load_environment_variables
    validate_requirements
    validate_oci_config
    test_oci_connection
    validate_always_free_limits
    
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1)
                deploy_complete
                break
                ;;
            2)
                deploy_initial
                break
                ;;
            3)
                health_check
                ;;
            4)
                show_outputs
                ;;
            5)
                destroy_infrastructure
                ;;
            0)
                print_status "Saindo..."
                exit 0
                ;;
            *)
                print_error "Invalid option!"
                ;;
        esac
        
        echo ""
        printf "Pressione Enter para continuar..."
        read -r
    done
}

if [ ! -f "main.tf" ] || [ ! -f "variables.tf" ]; then
    print_error "Run this script in the Terraform project directory!"
    exit 1
fi

main "$@"
