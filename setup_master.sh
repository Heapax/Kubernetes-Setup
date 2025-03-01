#!/bin/bash

# Define Kubernetes version
K8S_VERSION="1.32.2"
K8S_VERSION_MAJOR_MINOR="${K8S_VERSION%.*}"
CNI_VERSION="v1.2.0"
CALICO_VERSION="v3.26.1"
POD_NETWORK_CIDR="192.168.0.0/16"

# Exit script on any error
set -e

# Function to determine platform architecture
check_architecture() {
    echo "[System] Checking platform architecture..."
    ARCH=$(uname -m)
    case "$ARCH" in
        "aarch64") PLATFORM="arm64" ;;
        "x86_64") PLATFORM="amd64" ;;
        *) echo "[Error] Unsupported architecture: $ARCH. Only amd64 and arm64/aarch64 are supported."; exit 1 ;;
    esac
    echo "[System] Detected architecture: $ARCH, setting platform to $PLATFORM."
}

# Function to check and remove old Kubernetes versions
cleanup_old_k8s() {
    echo "[Cleanup] Removing old Kubernetes installations..."
    sudo kubeadm reset -f || true
    sudo apt-get remove -y kubelet kubeadm kubectl || true
    sudo apt-get autoremove -y || true
    sudo rm -rf ~/.kube /etc/kubernetes /var/lib/etcd /var/lib/kubelet
    echo "[Cleanup] Old Kubernetes installations removed."
}

# Function to update system packages
update_system() {
    echo "[System] Updating system packages..."
    sudo apt-get update && sudo apt-get upgrade -y
    echo "[System] System update complete."
}

# Function to install dependencies
install_dependencies() {
    echo "[Dependencies] Installing required packages..."
    sudo apt-get install -y apt-transport-https ca-certificates curl gpg software-properties-common vim bash-completion
    echo "[Dependencies] Packages installed."
}

# Function to install containerd
install_containerd() {
    echo "[Containerd] Installing containerd..."
    sudo apt-get install -y containerd
    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml
    sudo systemctl restart containerd
    sudo systemctl enable containerd
    echo "[Containerd] Containerd installed and configured."
}

# Function to install Kubernetes
install_kubernetes() {
    echo "[Kubernetes] Adding Kubernetes repository..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSLo /etc/apt/keyrings/kubernetes-apt-keyring.gpg https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_MAJOR_MINOR}/deb/Release.key
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_MAJOR_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update

    echo "[Kubernetes] Installing kubeadm, kubelet, and kubectl version $K8S_VERSION..."
    sudo apt-get install -y kubelet=${K8S_VERSION}-1.1 kubeadm=${K8S_VERSION}-1.1 kubectl=${K8S_VERSION}-1.1
    sudo apt-mark hold kubelet kubeadm kubectl
    echo "[Kubernetes] Kubernetes installation complete."
}

# Function to initialize the Kubernetes cluster
initialize_kubernetes() {
    echo "[Kubernetes] Initializing Kubernetes cluster..."
    sudo kubeadm init --pod-network-cidr=${POD_NETWORK_CIDR} --kubernetes-version=${K8S_VERSION} | tee kubeadm-init.log

    echo "[Kubernetes] Setting up kubectl for the current user..."
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config

    echo "[Kubernetes] Applying Calico CNI plugin..."
    curl -fsSL -o calico.yaml https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml
    kubectl apply -f calico.yaml
    echo "[Kubernetes] Calico networking configured."
}

# Function to install Podman
install_podman() {
    echo "[Podman] Installing Podman..."
    sudo apt-get install -y podman
    echo "[Podman] Podman installed."
}

# Function to update shell environment
configure_shell() {
    echo "[Configuration] Updating .bashrc and .vimrc..."
    echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc
    echo 'alias k=kubectl' >> ~/.bashrc
    echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc
    source ~/.bashrc

    echo 'set number' >> ~/.vimrc
    echo 'syntax on' >> ~/.vimrc
    echo "[Configuration] Shell environment updated."
}

# Function to output the join command for worker nodes
output_join_command() {
    echo "[Kubernetes] Fetching join command for worker nodes..."
    kubeadm token create --print-join-command | tee kubeadm-join-command.txt
    echo "[Kubernetes] Join command saved in kubeadm-join-command.txt"
}

# Run installation steps
check_architecture
cleanup_old_k8s
update_system
install_dependencies
install_containerd
install_kubernetes
initialize_kubernetes
install_podman
configure_shell
output_join_command

# Final message
echo "[Setup Complete] Kubernetes master node setup finished successfully!"
