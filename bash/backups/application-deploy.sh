#!/bin/bash

add_or_update_repo() {
    local repo_url=$1
    local repo_name=$2
    if helm repo list | grep -q "$repo_name" ; then
        existing_repo_url=$(helm repo list | awk -v name="$repo_name" '$1 == name {print $2}')
        if [ "$existing_repo_url" == "$repo_url" ]; then
            echo "Repository '$repo_name' is already added with URL '$repo_url'."
            return
        else
            echo "Repository with name '$repo_name' already exists but with a different URL ('$existing_repo_url'). Removing and adding with the new URL."
            helm repo remove "$repo_name"
            helm repo add "$repo_name" "$repo_url"
            echo "Repository '$repo_name' added successfully with URL '$repo_url'."
        fi
    else
        helm repo add "$repo_name" "$repo_url"
        echo "Repository '$repo_name' added successfully with URL '$repo_url'."
    fi
}

helm_install() {
    local release_name=$1
    local chart_name=$2
    local namespace=$3
    echo "HELM REPO = 'helm repo ls'"
    echo "RELEASE_NAME=$release_name"
    echo "CHART_NAME=$chart_name"
    echo "NAMESPACE=$namespace"

    helm install "$release_name" "$chart_name" -n "$namespace" --version "$version" -f /home/bcdr/"$namespace".yaml

    local end_time=$((SECONDS + 150))
    local all_pods_running=false

    while [ $SECONDS -lt $end_time ]; do
        if kubectl get pods -n "$namespace" | grep -q "^$release_name"; then
            local running_pods=$(kubectl get pods -n "$namespace" | grep "^$release_name" | grep -c "Running")
            local total_pods=$(kubectl get pods -n "$namespace" | grep "^$release_name" -c)
            if [ "$running_pods" -eq "$total_pods" ]; then
                all_pods_running=true
                break
            fi
        fi

        sleep 10
    done

    if [ "$all_pods_running" = true ]; then
        echo "All pods for release '$release_name' are running."
        kubectl get pods -n "$namespace"
    else
        echo "Timeout exceeded. Not all pods for release '$release_name' are in running state after 2.5 minutes."
        kubectl get pods -n "$namespace"
    fi
}

helm_upgrade() {
    local release_name=$1
    local chart_name=$2
    local namespace=$3
    echo "HELM REPO = 'helm repo ls'"
    echo "RELEASE_NAME=$release_name"
    echo "CHART_NAME=$chart_name"
    echo "NAMESPACE=$namespace"

    helm repo ls
    if helm list -n "$namespace" --short | grep -q "^$release_name$"; then
        helm upgrade "$release_name" "$chart_name" -n "$namespace" --version "$version" -f /home/bcdr/"$namespace".yaml

        local end_time=$((SECONDS + 150))
        local all_pods_running=false

        while [ $SECONDS -lt $end_time ]; do
            if kubectl get pods -n "$namespace" | grep -q "^$release_name"; then
                local running_pods=$(kubectl get pods -n "$namespace" | grep "^$release_name" | grep -c "Running")
                local total_pods=$(kubectl get pods -n "$namespace" | grep "^$release_name" -c)
                if [ "$running_pods" -eq "$total_pods" ]; then
                    all_pods_running=true
                    break
                fi
            fi

            sleep 10
        done

        if [ "$all_pods_running" = true ]; then
            echo "All pods for release '$release_name' are running after upgrade."
            kubectl get pods -n "$namespace"
        else
            echo "Timeout exceeded. Not all pods for release '$release_name' are in running state after 2.5 minutes."
            kubectl get pods -n "$namespace"
        fi
    else
        echo "Release name '$release_name' is not currently installed. Please install it first or use a different release name."
    fi
}

helm_uninstall() {
    local release_name=$1
    local namespace=$2
    echo "HELM REPO = 'helm repo ls'"
    echo "RELEASE_NAME=$release_name"
    echo "CHART_NAME=$chart_name"
    echo "NAMESPACE=$namespace"

    helm repo ls
    if helm list -n "$namespace" --short | grep -q "^$release_name$"; then
        helm uninstall "$release_name" -n "$namespace"

        local end_time=$((SECONDS + 150))
        local all_resources_terminated=false

        while [ $SECONDS -lt $end_time ]; do
            if ! kubectl get all -n "$namespace" | grep -q "^$release_name"; then
                all_resources_terminated=true
                break
            fi
            sleep 10
        done

        if [ "$all_resources_terminated" = true ]; then
            echo "All resources associated with release '$release_name' have been terminated after uninstallation."
            kubectl get pods -n "$namespace"
        else
            echo "Timeout exceeded. Not all resources associated with release '$release_name' have been terminated after 5 minutes."
            kubectl get pods -n "$namespace"
        fi
    else
        echo "Release name '$release_name' is not currently installed."
    fi
}

helm_operation() {
    local operation=$1
    local repo_url=$2
    local release_name=$3
    local namespace=$4

    add_or_update_repo "$repo_url" "insightsoftware"

    helm repo update

    chart_name=$(helm search repo insightsoftware | awk 'NR==2{print $1}')

    kubectl create ns "$namespace" --dry-run=client -o yaml | kubectl apply -f -

    case $operation in
        install)
            if helm list -n "$namespace" | grep -q "^$release_name"; then
                echo "Release '$release_name' is already installed."
            else
                helm_install "$release_name" "$chart_name" "$namespace" "$version"
            fi
            ;;
        upgrade)
            helm_upgrade "$release_name" "$chart_name" "$namespace" "$version"
            ;;
        uninstall)
            helm_uninstall "$release_name" "$namespace"
            ;;
        *)
            echo "Invalid operation: $operation. Supported operations are: install, upgrade, uninstall."
            ;;
    esac
}

main() {
    if [ $# -lt 5 ]; then
        echo "Usage: $0 <region> <customer_name> <helm_repo_url> <operation> <env_type> [<version>]"
        exit 1
    fi

    region="$1"
    customer_name="$2"
    release_name="$customer_name"
    namespace="$customer_name"
    repo_url=$3
    operation=$4
    env_type=$5
    version=$6
    export KUBECONFIG=/root/.kube/config

    helm_operation "$operation" "$repo_url" "$release_name" "$namespace" "$version"
}

main "$@"