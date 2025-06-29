#!/usr/bin/env bash

# Script for getting an overview about not up-to-date docker containers
# Set variable "TRACE" to "1" for debugging.
# Improved version with better error handling and accurate update detection

# sudo permissions for the user (nagios)
# nagios ALL=NOPASSWD: /usr/bin/docker ps *
# nagios ALL=NOPASSWD: /usr/bin/docker images *
# nagios ALL=NOPASSWD: /usr/bin/docker inspect *
# nagios ALL=NOPASSWD: /usr/bin/docker manifest inspect *

# Configuration
TIMEOUT=60
TEMP_DIR=$(mktemp -d)

# Cleanup function
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Error handling - more specific than the original trap
handle_error() {
    local exit_code=$?
    local line_no=$1
    echo "CRITICAL - Error occurred at line $line_no (exit code: $exit_code)"
    exit 2
}

# Set error handling but not as aggressive as the original
set -o nounset
set -o pipefail

# Function to check if docker command is available
check_docker_availability() {
    if ! command -v docker &> /dev/null; then
        echo "CRITICAL - Docker command not found"
        exit 2
    fi

    # Test docker access (with or without sudo)
    if sudo docker info &> /dev/null; then
        DOCKER_CMD="sudo docker"
    elif docker info &> /dev/null; then
        DOCKER_CMD="docker"
    else
        echo "CRITICAL - Cannot access Docker daemon"
        exit 2
    fi
}

# Function to normalize image names
normalize_image_name() {
    local image="$1"
    # Add :latest if no tag specified
    if [[ "$image" != *":"* ]]; then
        echo "${image}:latest"
    else
        echo "$image"
    fi
}

# Function to get remote digest without pulling
get_remote_digest() {
    local image="$1"
    local remote_digest=""
    
    # Try docker manifest inspect first
    local manifest_output
    if manifest_output=$($DOCKER_CMD manifest inspect "$image" 2>/dev/null); then
        remote_digest=$(echo "$manifest_output" | grep -o '"digest":"sha256:[a-f0-9]*"' | head -1 | cut -d'"' -f4 2>/dev/null || echo "")
        if [ -n "$remote_digest" ]; then
            echo "$remote_digest"
            return 0
        fi
    fi
    
    # Fallback: try skopeo if available
    if command -v skopeo &> /dev/null; then
        local skopeo_output
        if skopeo_output=$(skopeo inspect "docker://$image" 2>/dev/null); then
            remote_digest=$(echo "$skopeo_output" | grep -o '"Digest":"sha256:[a-f0-9]*"' | cut -d'"' -f4 2>/dev/null || echo "")
            if [ -n "$remote_digest" ]; then
                echo "$remote_digest"
                return 0
            fi
        fi
    fi
    
    return 1
}

# Function to get local image digest
get_local_digest() {
    local image="$1"
    local digest
    
    # Get the repo digest of the local image
    digest=$($DOCKER_CMD inspect "$image" --format='{{index .RepoDigests 0}}' 2>/dev/null)
    
    if [ -n "$digest" ] && [ "$digest" != "<no value>" ]; then
        # Extract just the SHA256 part after @
        echo "${digest#*@}"
        return 0
    fi
    
    return 1
}

main() {
    trap 'handle_error $LINENO' ERR
    
    echo "Checking Docker container updates..." >&2
    
    # Check Docker availability
    check_docker_availability
    
    # Get all running containers with their images
    local containers_file="$TEMP_DIR/containers.txt"
    local updates_file="$TEMP_DIR/updates.txt"
    
    # Get container info: ContainerName|ImageName
    $DOCKER_CMD ps --format "{{.Names}}|{{.Image}}" > "$containers_file"
    
    if [ ! -s "$containers_file" ]; then
        echo "OK - No running containers found"
        exit 0
    fi
    
    local checked_images=""
    local update_count=0
    local failed_count=0
    local total_containers=0
    
    # Process each container
    while IFS='|' read -r container_name image_name; do
        [ -z "$container_name" ] && continue
        total_containers=$((total_containers + 1))
        
        # Normalize image name
        image_name=$(normalize_image_name "$image_name")
        
        echo "Checking container: $container_name (image: $image_name)" >&2
        
        # Skip if we already checked this image (avoid duplicates)
        if [ -n "$checked_images" ] && echo "$checked_images" | grep -q "^${image_name}$" 2>/dev/null; then
            echo "  -> Already checked this image, skipping" >&2
            continue
        fi
        if [ -z "$checked_images" ]; then
            checked_images="$image_name"
        else
            checked_images="$checked_images"$'\n'"$image_name"
        fi
        
        # Get local image digest
        local_digest=$(get_local_digest "$image_name" || echo "")
        if [ -z "$local_digest" ]; then
            echo "  -> Warning: Cannot get local digest for $image_name" >&2
            failed_count=$((failed_count + 1))
            continue
        fi
        
        echo "  -> Local digest: ${local_digest:0:12}..." >&2
        
        # Get remote image digest
        remote_digest=$(get_remote_digest "$image_name" || echo "")
        if [ -z "$remote_digest" ]; then
            echo "  -> Warning: Cannot get remote digest for $image_name" >&2
            failed_count=$((failed_count + 1))
            continue
        fi
        
        echo "  -> Remote digest: ${remote_digest:0:12}..." >&2
        
        # Compare digests (only if both are valid SHA256 hashes)
        if [[ "$local_digest" =~ ^sha256:[a-f0-9]{64}$ ]] && [[ "$remote_digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
            if [ "$local_digest" != "$remote_digest" ]; then
                echo "  -> UPDATE AVAILABLE!" >&2
                echo "$container_name ($image_name)" >> "$updates_file"
                update_count=$((update_count + 1))
            else
                echo "  -> Up to date" >&2
            fi
        else
            echo "  -> Warning: Invalid digest format for $image_name" >&2
            failed_count=$((failed_count + 1))
        fi
        
    done < "$containers_file"
    
    # Generate output
    if [ $update_count -eq 0 ] && [ $failed_count -eq 0 ]; then
        echo "OK - All $total_containers container(s) are up to date"
        exit 0
    elif [ $update_count -eq 0 ] && [ $failed_count -gt 0 ]; then
        echo "WARNING - $failed_count container(s) could not be checked, but no updates found"
        exit 1
    elif [ $update_count -gt 0 ]; then
        echo "WARNING - $update_count container(s) have updates available:"
        if [ -s "$updates_file" ]; then
            cat "$updates_file"
        fi
        if [ $failed_count -gt 0 ]; then
            echo "Note: $failed_count container(s) could not be checked"
        fi
        exit 1
    fi
}

#### ARGUMENTS ####

if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

## MAIN ###
cd "$(dirname "$0")"

main "$@"