#!/bin/bash

# Define constants
DOCKER_VERSION="5:28.0.1-1~ubuntu.22.04~jammy" # Based on your Ubuntu version, change if necessary
K8S_VERSION="1.32.2"
K8S_POD_NETWORK_CIDR="192.168.0.0/16"

# Exit on any error
set -e

# Function to log messages in Syslog format (RFC 5424)
log() {
  local level="$1"
  local message="$2"
  logger -p "user.${level}" -t "setup-script" "${message}"
}

# Function to determine platform architecture
check_architecture() {
  log info "Checking platform architecture..."
  ARCH=$(uname -m)
  log info "Uname -m output: ${ARCH}"
  case "$ARCH" in
    "aarch64")
      log info "Detected aarch64 architecture."
      PLATFORM="arm64"
      ;;
    "x86_64")
      log info "Detected x86_64 architecture."
      PLATFORM="amd64"
      ;;
    *)
      log err "Unsupported architecture: $ARCH. Only amd64 and arm64/aarch64 are supported."
      exit 1
      ;;
  esac
  log info "Detected architecture: $ARCH, setting platform to $PLATFORM."
}

# Function to install required kernel modules
install_kernel_modules() {
  log info "Loading kernel modules..."
  echo -e "overlay\nbr_netfilter" | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
  sudo modprobe overlay
  sudo modprobe br_netfilter
  log info "Kernel modules loaded."
}

# Function to set sysctl parameters
set_sysctl_params() {
  log info "Setting sysctl parameters..."
  echo -e "net.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\nnet.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/k8s.conf >/dev/null
  sudo sysctl --system
  log info "Sysctl configuration reloaded."
}

# Function to install required packages
install_packages() {
  log info "Updating package list and installing required packages..."
  sudo apt-get update -y
  sudo apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common
  log info "Required packages installed."
}

# Function to set up Docker repository and install Docker
install_docker() {
  log info "Installing Docker..."
  sudo apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc || true
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce=${DOCKER_VERSION} docker-ce-cli=${DOCKER_VERSION} containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "${USER}"
  log info "Docker installed and user added to docker group."
}

# Function to configure containerd
configure_containerd() {
  log info "Configuring containerd..."
  sudo sed -i 's/disabled_plugins/#disabled_plugins/' /etc/containerd/config.toml
  sudo systemctl restart containerd
  log info "Containerd configured and restarted."
}

# Function to disable swap
disable_swap() {
  log info "Disabling swap space..."
  sudo swapoff -a
  sudo sed -i '/\sswap\s/ s/^/#/' /etc/fstab
  log info "Swap disabled."
}

# Function to install Kubernetes components
install_k8s() {
  log info "Installing Kubernetes components..."
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
  sudo apt-get update -y
  sudo apt-get install -y kubelet=${K8S_VERSION}-* kubeadm=${K8S_VERSION}-* kubectl=${K8S_VERSION}-*
  sudo apt-mark hold kubelet kubeadm kubectl
  log info "Kubernetes components installed."
}

# Function to initialize the Kubernetes cluster
initialize_cluster() {
  log info "Initializing Kubernetes cluster..."
  if sudo kubeadm init --pod-network-cidr=$K8S_POD_NETWORK_CIDR --kubernetes-version $K8S_VERSION; then
    log info "kubeadm init successful."
  else
    log err "kubeadm init failed."
    exit 1
  fi
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  log info "Kubernetes cluster initialized."
}

# Function to install Calico network add-on
install_calico() {
  log info "Installing Calico network add-on..."
  if kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml; then
    log info "Calico installed."
  else
    log err "Failed to install Calico."
    exit 1
  fi
}

# Function to get the kubeadm join command
get_join_command() {
  log info "Retrieving Kubernetes join command..."
  if join_command=$(kubeadm token create --print-join-command 2>&1); then
    log info "Join command retrieved successfully."
    echo "${join_command}"
  else
    log err "Failed to retrieve join command."
    exit 1
  fi
}

# Main function
main() {
  check_architecture
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

# Execute main function
main