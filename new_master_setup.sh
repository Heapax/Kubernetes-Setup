#!/bin/bash

# Define constants
DOCKER_VERSION="5:28.0.1-1~ubuntu.22.04~jammy" # Based on your Ubuntu version, change if necessary
K8S_VERSION="1.32.2"
K8S_POD_NETWORK_CIDR="192.168.0.0/16"

# Exit on any error
set -e

# Function to determine platform architecture
check_architecture() {
  echo "[System] Checking platform architecture..."
  echo "[System] Uname -m output: $(uname -m)"
  case "$ARCH" in
    "aarch64")
      echo "[System] Detected aarch64 architecture."
      PLATFORM="arm64"
      ;;
    "x86_64")
      echo "[System] Detected x86_64 architecture."
      PLATFORM="amd64"
      ;;
    *)
      echo "[Error] Unsupported architecture: $ARCH. Only amd64 and arm64/aarch64 are supported."
      exit 1
      ;;
  esac
  echo "[System] Detected architecture: $ARCH, setting platform to $PLATFORM."
}

# Function to install required kernel modules
install_kernel_modules() {
  echo "Loading kernel modules..."
  cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

  sudo modprobe overlay
  sudo modprobe br_netfilter
}

# Function to set sysctl parameters
set_sysctl_params() {
  echo "Setting sysctl parameters..."
  cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

  sudo sysctl --system
}

# Function to install required packages
install_packages() {
  echo "Installing packages..."
  sudo apt-get update
  sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common
}

# Function to set up Docker repository and install Docker
install_docker() {
  # Uninstall old versions of Docker
  sudo apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc || true

  # Add Docker's official GPG key
  sudo mkdir -m 0755 -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  # Set up the Docker repository
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update

  # Install Docker Engine, containerd, and Docker Compose
  sudo apt-get install -y \
    docker-ce=${DOCKER_VERSION} \
    docker-ce-cli=${DOCKER_VERSION} \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  # Add current user to docker group
  sudo usermod -aG docker "${USER}"
}

# Function to configure containerd
configure_containerd() {
  echo "Configuring containerd..."
  sudo sed -i 's/disabled_plugins/#disabled_plugins/' /etc/containerd/config.toml
  sudo systemctl restart containerd
}

# Function to disable swap
disable_swap() {
  echo "Disabling swap..."
  sudo swapoff -a
}

# Function to install kubeadm, kubelet, kubectl
install_k8s() {
  echo "Installing Kubernetes components..."
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

  sudo apt-get update
  sudo apt-get install -y kubelet=${K8S_VERSION}-* kubeadm=${K8S_VERSION}-* kubectl=${K8S_VERSION}-*

  # Mark Kubernetes components to hold for updates
  sudo apt-mark hold kubelet kubeadm kubectl
}

# Function to initialize the Kubernetes cluster (on control plane node)
initialize_cluster() {
  echo "Initializing Kubernetes cluster..."
  sudo kubeadm init --pod-network-cidr=$K8S_POD_NETWORK_CIDR --kubernetes-version $K8S_VERSION

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

  # Verify the cluster is working
  kubectl get nodes
}

# Function to install Calico network add-on
install_calico() {
  echo "Installing Calico network add-on..."
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml
}

# Function to get the kubeadm join command (for worker nodes)
get_join_command() {
  echo "Getting the join command..."
  kubeadm token create --print-join-command
}

# Main function to orchestrate the installation process
main() {
  install_kernel_modules
  set_sysctl_params
  install_packages
  install_docker
  configure_containerd
  disable_swap
  install_k8s
  initialize_cluster
  install_calico
  get_join_command
}

# Execute the main function
main