#!/usr/bin/env bash

# Script for getting an overview about not up-to-date docker containers
# Set variable "TRACE" to "1" for debugging.

# sudo permissions for the user (nagios)
# nagios ALL=NOPASSWD: /usr/bin/docker pull *
# nagios ALL=NOPASSWD: /usr/bin/docker ps -qa
# nagios ALL=NOPASSWD: /usr/bin/docker images -q
# nagios ALL=NOPASSWD: /usr/bin/docker inspect --format *
# nagios ALL=NOPASSWD: /usr/bin/docker images -aq --no-trunc *

remove_prefix_if_domain_exists() {
    url="$1"
    # Check for pattern *.* before the first /
    if [[ $url =~ ^[^/]*\.[a-zA-Z]{2,} ]]; then
        parts=(${url//\// })
        if [ ${#parts[@]} -gt 1 ]; then
            echo "${url#*/}"
        else
            echo "$url"
        fi
    else
        echo "$url"
    fi
}

main() {
    # FIX 1: Remove aggressive error trap that caused "ERROR - An error has occurred."
    # Only set basic error handling without errexit
    set -o nounset
    set -o pipefail

    # check for sudo:
    if ! sudo /usr/bin/docker images -aq --no-trunc '*' >> /dev/null 2>&1; then
        echo "CRITICAL - Cannot access Docker"
        exit 2
    fi

    # Get unique repository:tag combinations to avoid duplicates
    UNIQUE_REPOS=$(sudo docker images --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>" | sort -u)

    # FIX 2: Instead of pulling all images, check each container individually
    # This prevents false positives from pulled images
    UPD=""
    for CONTAINER in $(sudo docker ps -qa); do
        NAME=$(sudo docker inspect --format '{{.Name}}' $CONTAINER | sed "s/\///g")
        REPO=$(sudo docker inspect --format '{{.Config.Image}}' $CONTAINER)

        # Remove the domain part if it exists.
        REPO=$(remove_prefix_if_domain_exists "$REPO")

        # Skip if we can't determine the repository
        if [ -z "$REPO" ] || [ "$REPO" = "<none>" ]; then
            continue
        fi

        # Get current running image ID
        IMG_RUNNING=$(sudo docker inspect --format '{{.Image}}' $CONTAINER)
        
        # Try to pull the image to check for updates (but don't output anything)
        if sudo docker pull "$REPO" > /dev/null 2>&1; then
            # Get the latest image ID after potential pull
            IMG_LATEST=$(sudo docker images -aq --no-trunc "$REPO" | head -n1)

            # Compare image IDs - only report if they differ
            if [ -n "$IMG_LATEST" ] && [ "$IMG_RUNNING" != "$IMG_LATEST" ]; then
                if [ -n "$UPD" ]; then
                    UPD="${UPD}, ${NAME}"
                else
                    UPD="${NAME}"
                fi
            fi
        fi
    done

    if [ -n "$UPD" ]; then
        echo "WARNING - Update available for these containers:"
        echo "${UPD}"
        exit 1
    else
        echo "OK - no updates needed"
        exit 0
    fi
}

#### ARGUMENTS ####

if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

## MAIN ###
cd "$(dirname "$0")"

main "$@"