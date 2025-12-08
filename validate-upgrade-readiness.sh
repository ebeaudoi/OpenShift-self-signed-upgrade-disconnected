#!/bin/bash

################################################################################
# OpenShift Upgrade Readiness Validation Script
#
# This script validates all prerequisites and configuration steps required for
# upgrading an OpenShift cluster in a disconnected environment.
#
# Usage: ./validate-upgrade-readiness.sh
################################################################################

set -euo pipefail

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
CRITICAL_FAILURES=0

# Input variables
SOURCE_VERSION=""
TARGET_VERSION=""
OSUS_NAMESPACE="openshift-update-service"
OSUS_APP_NAME="update-service-oc-mirror"
REGISTRY_CA_CM_NAME=""
RELEASE_SIG_PATH=""

# Debug/Verbose mode flag
DEBUG=false

################################################################################
# Command-line Argument Parsing
################################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --debug|-d)
                DEBUG=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --debug, -d    Enable debug mode to display executed commands"
                echo "  --help, -h     Display this help message"
                echo ""
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

################################################################################
# Helper Functions
################################################################################

debug_cmd() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${YELLOW}[DEBUG] Executing: $1${NC}" >&2
    fi
}

print_header() {
    echo ""
    echo "================================================================================"
    echo "$1"
    echo "================================================================================"
    echo ""
}

print_check() {
    local check_name="$1"
    printf "  %-70s" "$check_name"
}

print_pass() {
    echo -e "${GREEN}[✓ PASS]${NC}"
    ((PASSED++))
}

print_fail() {
    local message="$1"
    local critical="${2:-false}"
    echo -e "${RED}[✗ FAIL]${NC}"
    if [[ -n "$message" ]]; then
        echo -e "    ${RED}→ $message${NC}"
    fi
    ((FAILED++))
    if [[ "$critical" == "true" ]]; then
        ((CRITICAL_FAILURES++))
    fi
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}[! WARN]${NC}"
    if [[ -n "$message" ]]; then
        echo -e "    ${YELLOW}→ $message${NC}"
    fi
}

check_resource_exists() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="${3:-}"
    
    if [[ -n "$namespace" ]]; then
        debug_cmd "oc get $resource_type $resource_name -n $namespace"
        oc get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null
    else
        debug_cmd "oc get $resource_type $resource_name"
        oc get "$resource_type" "$resource_name" &>/dev/null
    fi
}

get_jsonpath() {
    local resource_type="$1"
    local resource_name="$2"
    local jsonpath="$3"
    local namespace="${4:-}"
    
    if [[ -n "$namespace" ]]; then
        debug_cmd "oc get $resource_type $resource_name -n $namespace -o jsonpath='$jsonpath'"
        oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath="$jsonpath" 2>/dev/null || echo ""
    else
        debug_cmd "oc get $resource_type $resource_name -o jsonpath='$jsonpath'"
        oc get "$resource_type" "$resource_name" -o jsonpath="$jsonpath" 2>/dev/null || echo ""
    fi
}

################################################################################
# Input Collection
################################################################################

collect_inputs() {
    print_header "OpenShift Upgrade Readiness Validation"
    
    echo "This script will validate all prerequisites and configuration steps"
    echo "required for upgrading your OpenShift cluster in a disconnected environment."
    echo ""
    
    # Display version format example
    echo "Version Format: Use standard OpenShift version format (e.g., 4.14.0, 4.15.2, 4.18.23)"
    echo ""
    
    # Attempt to auto-detect current OpenShift version
    local detected_version=""
    echo "Attempting to auto-detect current OpenShift version..."
    if command -v oc &>/dev/null && oc whoami &>/dev/null 2>&1; then
        # Try to get version from clusterversion
        debug_cmd "oc get clusterversion version -o jsonpath='{.status.desired.version}'"
        detected_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "")
        if [[ -z "$detected_version" ]]; then
            # Try alternative method
            debug_cmd "oc get clusterversion version -o jsonpath='{.status.history[?(@.state==\"Completed\")].version}' | head -n1"
            detected_version=$(oc get clusterversion version -o jsonpath='{.status.history[?(@.state=="Completed")].version}' 2>/dev/null | head -n1 || echo "")
        fi
        if [[ -n "$detected_version" ]]; then
            echo -e "${GREEN}→ Detected current version: $detected_version${NC}"
        else
            echo -e "${YELLOW}→ Could not auto-detect current version${NC}"
        fi
    else
        echo -e "${YELLOW}→ Cannot auto-detect: oc CLI not available or not authenticated${NC}"
    fi
    echo ""
    
    # Collect current version (source)
    local auto_detected_current=false
    if [[ -n "$detected_version" ]]; then
        read -p "Enter current OpenShift version (source) [$detected_version]: " SOURCE_VERSION
        if [[ -z "$SOURCE_VERSION" ]]; then
            SOURCE_VERSION="$detected_version"
            auto_detected_current=true
        fi
    else
        while [[ -z "$SOURCE_VERSION" ]]; do
            read -p "Enter current OpenShift version (source): " SOURCE_VERSION
            if [[ -z "$SOURCE_VERSION" ]]; then
                echo -e "${RED}Error: Source version is required${NC}"
            fi
        done
    fi
    
    # Collect target version
    while [[ -z "$TARGET_VERSION" ]]; do
        read -p "Enter target OpenShift version: " TARGET_VERSION
        if [[ -z "$TARGET_VERSION" ]]; then
            echo -e "${RED}Error: Target version is required${NC}"
        fi
    done
    
    echo ""
    echo "Optional configuration (press Enter for defaults):"
    read -p "OSUS namespace [${OSUS_NAMESPACE}]: " input
    if [[ -n "$input" ]]; then
        OSUS_NAMESPACE="$input"
    fi
    
    read -p "OSUS application name [${OSUS_APP_NAME}]: " input
    if [[ -n "$input" ]]; then
        OSUS_APP_NAME="$input"
    fi
    
    read -p "Registry CA ConfigMap name (leave empty to auto-detect): " REGISTRY_CA_CM_NAME
    
    # Prompt for debug mode if not already set via command-line flag
    if [[ "$DEBUG" == "false" ]]; then
        echo ""
        read -p "Enable debug mode to display executed commands? (y/N): " debug_input
        if [[ "${debug_input,,}" == "y" || "${debug_input,,}" == "yes" ]]; then
            DEBUG=true
        fi
    fi
    
    echo ""
    echo "================================================================================"
    echo "Version Confirmation"
    echo "================================================================================"
    echo ""
    
    # Prompt for confirmation with loop to allow corrections
    local confirmed=false
    while [[ "$confirmed" == "false" ]]; do
        # Re-check for missing versions each iteration
        local missing_versions=false
        
        # Display versions for confirmation
        echo "Current OpenShift Version (Source):"
        if [[ -n "$SOURCE_VERSION" ]]; then
            if [[ "$auto_detected_current" == "true" ]]; then
                echo -e "  ${GREEN}✓ $SOURCE_VERSION${NC} (auto-detected)"
            else
                echo -e "  ${GREEN}✓ $SOURCE_VERSION${NC}"
            fi
        else
            echo -e "  ${RED}✗ NOT SET${NC}"
            missing_versions=true
        fi
        
        echo ""
        echo "Target OpenShift Version:"
        if [[ -n "$TARGET_VERSION" ]]; then
            echo -e "  ${GREEN}✓ $TARGET_VERSION${NC}"
        else
            echo -e "  ${RED}✗ NOT SET${NC}"
            missing_versions=true
        fi
        
        echo ""
        
        # If versions are missing, make confirmation mandatory
        if [[ "$missing_versions" == "true" ]]; then
            echo -e "${RED}WARNING: One or more versions are missing or unconfirmed!${NC}"
            echo -e "${RED}You must confirm the versions before proceeding.${NC}"
            echo ""
        fi
        
        # Prompt for confirmation
        read -p "Confirm these versions are correct? (yes/no): " confirm_input
        confirm_input=$(echo "$confirm_input" | tr '[:upper:]' '[:lower:]')
        
        if [[ "$confirm_input" == "yes" ]] || [[ "$confirm_input" == "y" ]]; then
            if [[ "$missing_versions" == "true" ]]; then
                echo -e "${RED}Error: Cannot proceed with missing versions.${NC}"
                echo "Please re-enter the missing versions:"
                echo ""
                # Re-prompt for missing versions
                if [[ -z "$SOURCE_VERSION" ]]; then
                    while [[ -z "$SOURCE_VERSION" ]]; do
                        read -p "Enter current OpenShift version (source): " SOURCE_VERSION
                        if [[ -z "$SOURCE_VERSION" ]]; then
                            echo -e "${RED}Error: Source version is required${NC}"
                        fi
                    done
                fi
                if [[ -z "$TARGET_VERSION" ]]; then
                    while [[ -z "$TARGET_VERSION" ]]; do
                        read -p "Enter target OpenShift version: " TARGET_VERSION
                        if [[ -z "$TARGET_VERSION" ]]; then
                            echo -e "${RED}Error: Target version is required${NC}"
                        fi
                    done
                fi
                echo ""
                # Will loop back to show confirmation screen again
            else
                confirmed=true
            fi
        elif [[ "$confirm_input" == "no" ]] || [[ "$confirm_input" == "n" ]]; then
            echo ""
            echo "Please re-enter the versions:"
            echo ""
            SOURCE_VERSION=""
            TARGET_VERSION=""
            while [[ -z "$SOURCE_VERSION" ]]; do
                read -p "Enter current OpenShift version (source): " SOURCE_VERSION
                if [[ -z "$SOURCE_VERSION" ]]; then
                    echo -e "${RED}Error: Source version is required${NC}"
                fi
            done
            while [[ -z "$TARGET_VERSION" ]]; do
                read -p "Enter target OpenShift version: " TARGET_VERSION
                if [[ -z "$TARGET_VERSION" ]]; then
                    echo -e "${RED}Error: Target version is required${NC}"
                fi
            done
            echo ""
            # Reset auto-detection flag since user manually entered
            auto_detected_current=false
            # Will loop back to show confirmation screen again
        else
            echo -e "${YELLOW}Please enter 'yes' or 'no'${NC}"
            echo ""
        fi
    done
    
    echo ""
    echo "================================================================================"
    echo "Starting validation with confirmed versions..."
    echo "================================================================================"
    echo "Source Version: $SOURCE_VERSION"
    echo "Target Version: $TARGET_VERSION"
    echo "OSUS Namespace: $OSUS_NAMESPACE"
    echo "OSUS App Name: $OSUS_APP_NAME"
    echo ""
}

################################################################################
# Prerequisites Validation
################################################################################

validate_prerequisites() {
    print_header "Prerequisites Validation"
    
    # Check oc CLI installation
    print_check "oc CLI is installed and accessible"
    if command -v oc &>/dev/null; then
        print_pass
    else
        print_fail "oc CLI not found in PATH" true
        return 1
    fi
    
    # Check oc CLI version
    print_check "oc CLI version check"
    oc_version=$(oc version --client -o json 2>/dev/null | grep -oP '"gitVersion":\s*"\K[^"]+' || echo "")
    if [[ -n "$oc_version" ]]; then
        print_pass
        echo "    → oc version: $oc_version"
    else
        print_fail "Could not determine oc CLI version"
    fi
    
    # Check authentication
    print_check "User is authenticated to cluster"
    debug_cmd "oc whoami"
    if oc whoami &>/dev/null; then
        debug_cmd "oc whoami"
        current_user=$(oc whoami)
        print_pass
        echo "    → Authenticated as: $current_user"
    else
        print_fail "Not authenticated to cluster. Run 'oc login'" true
        return 1
    fi
    
    # Check cluster access
    print_check "Cluster is accessible"
    debug_cmd "oc cluster-info"
    if oc cluster-info &>/dev/null; then
        print_pass
        debug_cmd "oc cluster-info | head -n1 | awk '{print \$NF}'"
        cluster_url=$(oc cluster-info | head -n1 | awk '{print $NF}')
        echo "    → Cluster URL: $cluster_url"
    else
        print_fail "Cannot access cluster" true
        return 1
    fi
}

################################################################################
# Step 1: Cincinnati Operator Validation
################################################################################

validate_cincinnati_operator() {
    print_header "Step 1: Cincinnati Operator Validation"
    
    local step_failed=false
    
    # Check subscription exists
    print_check "Cincinnati operator subscription exists"
    debug_cmd "oc get subscription cincinnati-operator -n $OSUS_NAMESPACE"
    if check_resource_exists "subscription" "cincinnati-operator" "$OSUS_NAMESPACE"; then
        print_pass
    else
        print_fail "Subscription 'cincinnati-operator' not found in namespace '$OSUS_NAMESPACE'" true
        step_failed=true
    fi
    
    # Check CSV exists and is in Succeeded phase
    print_check "Cincinnati operator CSV is installed"
    debug_cmd "oc get csv -n $OSUS_NAMESPACE -o json | jq -r '.items[] | select(.spec.displayName==\"OpenShift Update Service\") | .metadata.name' | head -n1"
    csv_name=$(oc get csv -n "$OSUS_NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.spec.displayName=="OpenShift Update Service") | .metadata.name' | head -n1 || echo "")
    if [[ -z "$csv_name" ]]; then
        # Try alternative method - look for update-service-operator CSV (any version)
        debug_cmd "oc get csv -n $OSUS_NAMESPACE -o json | jq -r '.items[] | select(.metadata.name | startswith(\"update-service-operator\")) | .metadata.name' | head -n1"
        csv_name=$(oc get csv -n "$OSUS_NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | startswith("update-service-operator")) | .metadata.name' | head -n1 || echo "")
    fi
    
    if [[ -n "$csv_name" ]]; then
        csv_phase=$(get_jsonpath "csv" "$csv_name" "{.status.phase}" "$OSUS_NAMESPACE")
        if [[ "$csv_phase" == "Succeeded" ]]; then
            print_pass
            echo "    → CSV: $csv_name (Phase: $csv_phase)"
        else
            print_fail "CSV '$csv_name' is not in Succeeded phase (current: $csv_phase)" true
            step_failed=true
        fi
    else
        print_fail "Cincinnati operator CSV not found" true
        step_failed=true
    fi
    
    # Check operator pods
    print_check "Cincinnati operator pods are running"
    debug_cmd "oc get pods -n $OSUS_NAMESPACE --selector name=updateservice-operator --no-headers | wc -l"
    pod_count=$(oc get pods -n "$OSUS_NAMESPACE" --selector name=updateservice-operator --no-headers 2>/dev/null | wc -l || echo "0")
    pod_count=$(echo "$pod_count" | tr -d '\n\r')
    if [[ "$pod_count" -gt 0 ]]; then
        debug_cmd "oc get pods -n $OSUS_NAMESPACE --selector name=updateservice-operator --no-headers | grep -c Running"
        running_pods=$(oc get pods -n "$OSUS_NAMESPACE" --selector name=updateservice-operator --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        running_pods=$(echo "$running_pods" | tr -d '\n\r')
        if [[ "$running_pods" -gt 0 ]]; then
            print_pass
            echo "    → Found $running_pods running pod(s)"
        else
            print_fail "Operator pods exist but not all are Running" true
            step_failed=true
        fi
    else
        print_fail "No operator pods found with selector 'name=updateservice-operator'" true
        step_failed=true
    fi
    
    if [[ "$step_failed" == "true" ]]; then
        return 1
    fi
}

################################################################################
# Step 2: Release Signatures Validation
################################################################################

validate_release_signatures() {
    print_header "Step 2: Release Signatures Validation"
    
    local step_failed=false
    
    # Check release signatures ConfigMap exists
    print_check "Release signatures ConfigMap exists"
    if check_resource_exists "configmap" "mirrored-release-signatures" "openshift-config-managed"; then
        print_pass
    else
        print_fail "ConfigMap 'mirrored-release-signatures' not found in 'openshift-config-managed'" true
        step_failed=true
    fi
    
    # Check ConfigMap contains signature data
    print_check "Release signatures ConfigMap contains data"
    if check_resource_exists "configmap" "mirrored-release-signatures" "openshift-config-managed"; then
        debug_cmd "oc get configmap mirrored-release-signatures -n openshift-config-managed -o json | jq -r '.binaryData // {} | keys | length'"
        data_keys=$(get_jsonpath "configmap" "mirrored-release-signatures" "{.binaryData}" "openshift-config-managed" | jq -r 'keys | length' 2>/dev/null || echo "0")
        if [[ "$data_keys" -gt 0 ]]; then
            print_pass
            echo "    → ConfigMap contains $data_keys signature key(s)"
        else
            print_fail "ConfigMap exists but contains no signature data" true
            step_failed=true
        fi
    else
        print_fail "Cannot verify signature data - ConfigMap not found"
        step_failed=true
    fi
    
    if [[ "$step_failed" == "true" ]]; then
        return 1
    fi
}

################################################################################
# Step 3: Registry Access Configuration Validation
################################################################################

validate_registry_access() {
    print_header "Step 3: Registry Access Configuration Validation"
    
    local step_failed=false
    
    # Auto-detect registry CA ConfigMap if not provided
    local registry_cm_name="$REGISTRY_CA_CM_NAME"
    if [[ -z "$registry_cm_name" ]]; then
        # Try to find it from Image config
        registry_cm_name=$(get_jsonpath "image.config.openshift.io" "cluster" "{.spec.additionalTrustedCA.name}")
        if [[ -z "$registry_cm_name" ]]; then
            # Try common names
            for cm_name in "my-registry-ca" "registry-ca" "additional-trusted-ca"; do
                if check_resource_exists "configmap" "$cm_name" "openshift-config"; then
                    registry_cm_name="$cm_name"
                    break
                fi
            done
        fi
    fi
    
    # Check registry CA ConfigMap exists
    print_check "Registry CA ConfigMap exists"
    if [[ -n "$registry_cm_name" ]] && check_resource_exists "configmap" "$registry_cm_name" "openshift-config"; then
        print_pass
        echo "    → ConfigMap: $registry_cm_name"
    else
        print_fail "Registry CA ConfigMap not found in 'openshift-config' namespace" true
        step_failed=true
        registry_cm_name=""
    fi
    
    # Check Image config references the ConfigMap
    print_check "Image config references registry CA ConfigMap"
    if [[ -n "$registry_cm_name" ]]; then
        image_cm_ref=$(get_jsonpath "image.config.openshift.io" "cluster" "{.spec.additionalTrustedCA.name}")
        if [[ "$image_cm_ref" == "$registry_cm_name" ]]; then
            print_pass
            echo "    → Image config references: $registry_cm_name"
        else
            print_fail "Image config references '$image_cm_ref' but expected '$registry_cm_name'" true
            step_failed=true
        fi
    else
        print_fail "Cannot verify - registry CA ConfigMap not found"
        step_failed=true
    fi
    
    # Check ConfigMap contains valid certificate data
    print_check "Registry CA ConfigMap contains valid certificate data"
    if [[ -n "$registry_cm_name" ]] && check_resource_exists "configmap" "$registry_cm_name" "openshift-config"; then
        cert_count=$(oc get configmap "$registry_cm_name" -n openshift-config -o json 2>/dev/null | jq -r '.data | keys | length' || echo "0")
        if [[ "$cert_count" -gt 0 ]]; then
            # Check if at least one key contains certificate-like data
            has_cert=false
            for key in $(oc get configmap "$registry_cm_name" -n openshift-config -o json 2>/dev/null | jq -r '.data | keys[]' || echo ""); do
                cert_data=$(get_jsonpath "configmap" "$registry_cm_name" "{.data.$key}" "openshift-config")
                if echo "$cert_data" | grep -q "BEGIN CERTIFICATE"; then
                    has_cert=true
                    break
                fi
            done
            if [[ "$has_cert" == "true" ]]; then
                print_pass
                echo "    → ConfigMap contains $cert_count certificate key(s)"
            else
                print_fail "ConfigMap exists but does not contain valid certificate data" true
                step_failed=true
            fi
        else
            print_fail "ConfigMap exists but contains no data" true
            step_failed=true
        fi
    else
        print_fail "Cannot verify - registry CA ConfigMap not found"
        step_failed=true
    fi
    
    if [[ "$step_failed" == "true" ]]; then
        return 1
    fi
}

################################################################################
# Step 4: Router CA Configuration Validation
################################################################################

validate_router_ca() {
    print_header "Step 4: Router CA Configuration Validation"
    
    local step_failed=false
    
    # Check router CA secret exists
    print_check "Router CA secret exists"
    if check_resource_exists "secret" "router-ca" "openshift-ingress-operator"; then
        print_pass
    else
        print_fail "Secret 'router-ca' not found in 'openshift-ingress-operator' namespace" true
        step_failed=true
    fi
    
    # Check router CA certificate is in user-ca-bundle
    print_check "Router CA certificate in user-ca-bundle ConfigMap"
    if check_resource_exists "configmap" "user-ca-bundle" "openshift-config"; then
        # Get router CA certificate
        router_cert=$(get_jsonpath "secret" "router-ca" "{.data.tls\\.crt}" "openshift-ingress-operator" | base64 -d 2>/dev/null || echo "")
        if [[ -n "$router_cert" ]]; then
            # Check if user-ca-bundle contains router CA
            debug_cmd "oc get configmap user-ca-bundle -n openshift-config -o json"
            user_ca_bundle=$(oc get configmap user-ca-bundle -n openshift-config -o json 2>/dev/null || echo "{}")
            # Extract certificate from router CA (first cert in chain) - remove all whitespace for comparison
            router_cert_clean=$(echo "$router_cert" | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' | head -n -1 | tail -n +2 | tr -d '\n' | tr -d '[:space:]')
            
            # Check if any key in user-ca-bundle contains the router cert
            # Use bracket notation to handle keys with special characters (e.g., ca-bundle.crt)
            found=false
            for key in $(echo "$user_ca_bundle" | jq -r '.data // {} | keys[]' 2>/dev/null || echo ""); do
                # Use bracket notation to properly access keys with special characters
                debug_cmd "jq -r --arg k \"$key\" '.data[\$k]' (from user-ca-bundle)"
                cert_data=$(echo "$user_ca_bundle" | jq -r --arg k "$key" '.data[$k] // ""' 2>/dev/null || echo "")
                if [[ -n "$cert_data" ]] && echo "$cert_data" | grep -q "BEGIN CERTIFICATE"; then
                    # Remove all whitespace from cert_data and check if router cert is contained
                    cert_data_clean=$(echo "$cert_data" | tr -d '[:space:]')
                    if [[ "$cert_data_clean" == *"$router_cert_clean"* ]]; then
                        found=true
                        break
                    fi
                fi
            done
            
            if [[ "$found" == "true" ]]; then
                print_pass
            else
                print_fail "Router CA certificate not found in user-ca-bundle ConfigMap" true
                step_failed=true
            fi
        else
            print_fail "Could not extract router CA certificate from secret" true
            step_failed=true
        fi
    else
        print_fail "user-ca-bundle ConfigMap not found in 'openshift-config' namespace" true
        step_failed=true
    fi
    
    # Check Proxy config references user-ca-bundle
    print_check "Proxy config references user-ca-bundle"
    proxy_trusted_ca=$(get_jsonpath "proxies.config.openshift.io" "cluster" "{.spec.trustedCA.name}")
    if [[ "$proxy_trusted_ca" == "user-ca-bundle" ]]; then
        print_pass
    else
        print_fail "Proxy config does not reference 'user-ca-bundle' (current: ${proxy_trusted_ca:-none})" true
        step_failed=true
    fi
    
    if [[ "$step_failed" == "true" ]]; then
        return 1
    fi
}

################################################################################
# Step 5: OSUS Application Validation
################################################################################

validate_osus_application() {
    print_header "Step 5: OSUS Application Validation"
    
    local step_failed=false
    
    # Check OSUS application exists
    print_check "OSUS application (UpdateService) exists"
    if check_resource_exists "updateservice" "$OSUS_APP_NAME" "$OSUS_NAMESPACE"; then
        print_pass
    else
        print_fail "UpdateService '$OSUS_APP_NAME' not found in namespace '$OSUS_NAMESPACE'" true
        step_failed=true
    fi
    
    # Check OSUS pods are running
    print_check "OSUS pods are running and ready"
    if check_resource_exists "updateservice" "$OSUS_APP_NAME" "$OSUS_NAMESPACE"; then
        # Get deployment name - try to find deployment owned by UpdateService, or use UpdateService name as pattern
        debug_cmd "oc get deployments -n $OSUS_NAMESPACE -o json | jq -r '.items[] | select(.metadata.ownerReferences[]?.name==\"$OSUS_APP_NAME\") | .metadata.name' | head -n1"
        deployment_name=$(oc get deployments -n "$OSUS_NAMESPACE" -o json 2>/dev/null | jq -r --arg us_name "$OSUS_APP_NAME" '.items[] | select(.metadata.ownerReferences[]?.name==$us_name) | .metadata.name' 2>/dev/null | head -n1 || echo "")
        
        # If no deployment found via ownerReference, try to find by name pattern or use UpdateService name
        if [[ -z "$deployment_name" ]]; then
            # Try to find deployment with name matching UpdateService pattern
            debug_cmd "oc get deployments -n $OSUS_NAMESPACE -o json | jq -r '.items[] | select(.metadata.name | contains(\"$OSUS_APP_NAME\")) | .metadata.name' | head -n1"
            deployment_name=$(oc get deployments -n "$OSUS_NAMESPACE" -o json 2>/dev/null | jq -r --arg us_name "$OSUS_APP_NAME" '.items[] | select(.metadata.name | contains($us_name)) | .metadata.name' 2>/dev/null | head -n1 || echo "")
        fi
        
        # Fallback to UpdateService name if still not found
        if [[ -z "$deployment_name" ]]; then
            deployment_name="$OSUS_APP_NAME"
        fi
        
        # Check pods
        debug_cmd "oc get pods -n $OSUS_NAMESPACE --no-headers | grep -c $deployment_name"
        pod_count=$(oc get pods -n "$OSUS_NAMESPACE" --no-headers 2>/dev/null | grep -c "$deployment_name" || echo "0")
        pod_count=$(echo "$pod_count" | tr -d '\n\r')
        if [[ "$pod_count" -gt 0 ]]; then
            debug_cmd "oc get pods -n $OSUS_NAMESPACE --no-headers | grep $deployment_name | grep -c 'Running.*1/1\\|Running.*2/2'"
            ready_pods=$(oc get pods -n "$OSUS_NAMESPACE" --no-headers 2>/dev/null | grep "$deployment_name" | grep -c "Running.*1/1\|Running.*2/2" || echo "0")
            ready_pods=$(echo "$ready_pods" | tr -d '\n\r')
            if [[ "$ready_pods" -gt 0 ]]; then
                print_pass
                echo "    → Found $ready_pods ready pod(s) out of $pod_count total"
            else
                print_fail "OSUS pods exist but not all are ready" true
                step_failed=true
            fi
        else
            print_fail "No OSUS pods found for deployment '$deployment_name'" true
            step_failed=true
        fi
    else
        print_fail "Cannot verify pods - UpdateService not found"
        step_failed=true
    fi
    
    # Check OSUS route exists
    print_check "OSUS route exists"
    debug_cmd "oc get routes -n $OSUS_NAMESPACE --no-headers | wc -l"
    route_count=$(oc get routes -n "$OSUS_NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
    route_count=$(echo "$route_count" | tr -d '\n\r')
    if [[ "$route_count" -gt 0 ]]; then
        print_pass
        echo "    → Found $route_count route(s)"
    else
        print_warning "No routes found in namespace '$OSUS_NAMESPACE' (may be using NodePort/LoadBalancer)"
    fi
    
    # Check OSUS has valid policyEngineURI
    print_check "OSUS has valid policyEngineURI status"
    if check_resource_exists "updateservice" "$OSUS_APP_NAME" "$OSUS_NAMESPACE"; then
        policy_engine_uri=$(get_jsonpath "updateservice" "$OSUS_APP_NAME" "{.status.policyEngineURI}" "$OSUS_NAMESPACE")
        if [[ -n "$policy_engine_uri" ]] && [[ "$policy_engine_uri" != "null" ]]; then
            print_pass
            echo "    → Policy Engine URI: $policy_engine_uri"
        else
            print_fail "UpdateService does not have a valid policyEngineURI in status" true
            step_failed=true
        fi
    else
        print_fail "Cannot verify - UpdateService not found"
        step_failed=true
    fi
    
    if [[ "$step_failed" == "true" ]]; then
        return 1
    fi
}

################################################################################
# Step 6: CVO Configuration Validation
################################################################################

validate_cvo_configuration() {
    print_header "Step 6: CVO Configuration Validation"
    
    local step_failed=false
    
    # Check CVO is configured with upstream pointing to OSUS
    print_check "CVO upstream points to OSUS (not api.openshift.com)"
    cvo_upstream=$(get_jsonpath "clusterversion" "version" "{.spec.upstream}")
    if [[ -n "$cvo_upstream" ]] && [[ "$cvo_upstream" != "null" ]]; then
        if [[ "$cvo_upstream" != *"api.openshift.com"* ]]; then
            print_pass
            echo "    → Upstream: $cvo_upstream"
        else
            print_fail "CVO upstream still points to api.openshift.com: $cvo_upstream" true
            step_failed=true
        fi
    else
        print_fail "CVO upstream is not configured" true
        step_failed=true
    fi
    
    # Check CVO upstream URL matches OSUS policy engine URI
    print_check "CVO upstream URL matches OSUS policy engine URI"
    if [[ -n "$cvo_upstream" ]] && [[ "$cvo_upstream" != "null" ]]; then
        policy_engine_uri=$(get_jsonpath "updateservice" "$OSUS_APP_NAME" "{.status.policyEngineURI}" "$OSUS_NAMESPACE")
        if [[ -n "$policy_engine_uri" ]] && [[ "$policy_engine_uri" != "null" ]]; then
            # Extract base URL from policy engine URI (remove /api/upgrades_info/v1/graph if present)
            policy_base=$(echo "$policy_engine_uri" | sed 's|/api/upgrades_info/v1/graph.*||')
            cvo_base=$(echo "$cvo_upstream" | sed 's|/api/upgrades_info/v1/graph.*||')
            
            if [[ "$cvo_base" == "$policy_base" ]] || [[ "$cvo_upstream" == *"$policy_base"* ]]; then
                print_pass
            else
                print_warning "CVO upstream may not match OSUS policy engine URI exactly"
                echo "    → CVO: $cvo_upstream"
                echo "    → OSUS: $policy_engine_uri"
            fi
        else
            print_warning "Cannot verify match - OSUS policyEngineURI not available"
        fi
    else
        print_fail "Cannot verify - CVO upstream not configured"
        step_failed=true
    fi
    
    # Check CVO pods are running
    print_check "CVO pods are running and healthy"
    debug_cmd "oc get pods -n openshift-cluster-version --no-headers | grep cluster-version-operator | wc -l"
    cvo_pods=$(oc get pods -n openshift-cluster-version --no-headers 2>/dev/null | grep "cluster-version-operator" | wc -l || echo "0")
    cvo_pods=$(echo "$cvo_pods" | tr -d '\n\r')
    if [[ "$cvo_pods" -gt 0 ]]; then
        debug_cmd "oc get pods -n openshift-cluster-version --no-headers | grep cluster-version-operator | grep -c Running"
        running_cvo_pods=$(oc get pods -n openshift-cluster-version --no-headers 2>/dev/null | grep "cluster-version-operator" | grep -c "Running" || echo "0")
        running_cvo_pods=$(echo "$running_cvo_pods" | tr -d '\n\r')
        if [[ "$running_cvo_pods" -gt 0 ]]; then
            print_pass
            echo "    → Found $running_cvo_pods running CVO pod(s)"
        else
            print_fail "CVO pods exist but not all are Running" true
            step_failed=true
        fi
    else
        print_fail "No CVO pods found" true
        step_failed=true
    fi
    
    # Check CVO can retrieve available updates
    print_check "CVO can retrieve available updates"
    debug_cmd "oc adm upgrade"
    if oc adm upgrade &>/dev/null; then
        debug_cmd "oc adm upgrade | grep -c $TARGET_VERSION"
        available_updates=$(oc adm upgrade 2>/dev/null | grep -c "$TARGET_VERSION" || echo "0")
        available_updates=$(echo "$available_updates" | tr -d '\n\r')
        if [[ "$available_updates" -gt 0 ]]; then
            print_pass
            echo "    → Target version $TARGET_VERSION is available"
        else
            # Check if any updates are available at all
            debug_cmd "oc adm upgrade | grep -E '^[0-9]+\\.[0-9]+\\.[0-9]+' | wc -l"
            update_count=$(oc adm upgrade 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+" | wc -l || echo "0")
            update_count=$(echo "$update_count" | tr -d '\n\r')
            if [[ "$update_count" -gt 0 ]]; then
                print_warning "Updates available but target version $TARGET_VERSION not found in list"
            else
                print_fail "CVO cannot retrieve available updates" true
                step_failed=true
            fi
        fi
    else
        print_fail "Cannot execute 'oc adm upgrade' command" true
        step_failed=true
    fi
    
    if [[ "$step_failed" == "true" ]]; then
        return 1
    fi
}

################################################################################
# General Cluster Health Validation
################################################################################

validate_cluster_health() {
    print_header "General Cluster Health Validation"
    
    local step_failed=false
    
    # Check all nodes are Ready
    print_check "All nodes are in Ready state"
    debug_cmd "oc get nodes --no-headers | wc -l"
    total_nodes=$(oc get nodes --no-headers 2>/dev/null | wc -l || echo "0")
    total_nodes=$(echo "$total_nodes" | tr -d '\n\r')
    debug_cmd "oc get nodes --no-headers | grep -c ' Ready '"
    ready_nodes=$(oc get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
    ready_nodes=$(echo "$ready_nodes" | tr -d '\n\r')
    if [[ "$total_nodes" -gt 0 ]] && [[ "$ready_nodes" == "$total_nodes" ]]; then
        print_pass
        echo "    → $ready_nodes/$total_nodes nodes Ready"
    else
        print_fail "$ready_nodes/$total_nodes nodes Ready (expected all $total_nodes)" true
        step_failed=true
    fi
    
    # Check critical cluster operators are not degraded
    print_check "Critical cluster operators are not degraded"
    debug_cmd "oc get clusteroperators --no-headers | grep -v 'True.*False.*False' | grep -c True"
    degraded_operators=$(oc get clusteroperators --no-headers 2>/dev/null | grep -v "True.*False.*False" | grep -c "True" || echo "0")
    degraded_operators=$(echo "$degraded_operators" | tr -d '\n\r')
    if [[ "$degraded_operators" -eq 0 ]]; then
        print_pass
    else
        print_fail "$degraded_operators operator(s) are degraded" true
        echo "    → Run 'oc get clusteroperators' to see details"
        step_failed=true
    fi
    
    # Check cluster version status shows no blocking conditions
    print_check "Cluster version status shows no blocking conditions"
    debug_cmd "oc get clusterversion version -o json | jq -r '.status.conditions[] | select(.status==\"True\" and (.type==\"Failing\" or .type==\"Invalid\" or .type==\"Error\")) | .type' | wc -l"
    blocking_conditions=$(oc get clusterversion version -o json 2>/dev/null | jq -r '.status.conditions[] | select(.status=="True" and (.type=="Failing" or .type=="Invalid" or .type=="Error")) | .type' 2>/dev/null | wc -l || echo "0")
    blocking_conditions=$(echo "$blocking_conditions" | tr -d '\n\r')
    if [[ "$blocking_conditions" -eq 0 ]]; then
        print_pass
    else
        print_fail "$blocking_conditions blocking condition(s) found in cluster version status" true
        echo "    → Run 'oc get clusterversion version -o yaml' to see details"
        step_failed=true
    fi
    
    # Check upgrade path is available
    print_check "Upgrade path to target version is available"
    debug_cmd "oc adm upgrade"
    if oc adm upgrade &>/dev/null; then
        debug_cmd "oc adm upgrade | grep -q $TARGET_VERSION"
        if oc adm upgrade 2>/dev/null | grep -q "$TARGET_VERSION"; then
            print_pass
            echo "    → Version $TARGET_VERSION is available for upgrade"
        else
            print_warning "Target version $TARGET_VERSION not found in available upgrades"
            echo "    → Run 'oc adm upgrade' to see available versions"
        fi
    else
        print_fail "Cannot check upgrade availability" true
        step_failed=true
    fi
    
    if [[ "$step_failed" == "true" ]]; then
        return 1
    fi
}

################################################################################
# Summary and Final Status
################################################################################

print_summary() {
    print_header "Validation Summary"
    
    total_checks=$((PASSED + FAILED))
    pass_percentage=$((PASSED * 100 / total_checks))
    
    echo "Total Checks: $total_checks"
    echo -e "Passed: ${GREEN}$PASSED${NC}"
    echo -e "Failed: ${RED}$FAILED${NC}"
    echo "Pass Rate: ${pass_percentage}%"
    echo ""
    
    if [[ "$CRITICAL_FAILURES" -eq 0 ]] && [[ "$FAILED" -eq 0 ]]; then
        echo -e "${GREEN}================================================================================"
        echo -e "✓ CLUSTER IS READY TO UPGRADE"
        echo -e "================================================================================"
        echo -e "${NC}"
        echo "All validation checks have passed. Your cluster is ready to proceed with the upgrade."
        echo ""
        echo "Next steps:"
        echo "  1. Review the upgrade path: oc adm upgrade"
        echo "  2. Initiate the upgrade via the web console or CLI"
        echo ""
        return 0
    elif [[ "$CRITICAL_FAILURES" -eq 0 ]]; then
        echo -e "${YELLOW}================================================================================"
        echo -e "⚠ CLUSTER MAY BE READY TO UPGRADE (with warnings)"
        echo -e "================================================================================"
        echo -e "${NC}"
        echo "Some non-critical checks failed. Review the failures above and proceed with caution."
        echo ""
        return 0
    else
        echo -e "${RED}================================================================================"
        echo -e "✗ CLUSTER IS NOT READY TO UPGRADE"
        echo -e "================================================================================"
        echo -e "${NC}"
        echo "Critical validation checks have failed. Please address the following issues:"
        echo ""
        echo "  • Review all failed checks marked with [✗ FAIL] above"
        echo "  • Refer to the project README.md for detailed configuration steps"
        echo "  • Ensure all prerequisites and configuration steps are completed"
        echo ""
        return 1
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    # Parse command-line arguments
    parse_arguments "$@"
    
    collect_inputs
    
    # Run all validations
    validate_prerequisites || true
    validate_cincinnati_operator || true
    validate_release_signatures || true
    validate_registry_access || true
    validate_router_ca || true
    validate_osus_application || true
    validate_cvo_configuration || true
    validate_cluster_health || true
    
    # Print summary and exit
    if print_summary; then
        exit 0
    else
        exit 1
    fi
}

# Run main function
main

