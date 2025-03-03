#!/bin/bash

# Define Kubernetes version
K8S_VERSION="1.32.2"
K8S_VERSION_MAJOR_MINOR="${K8S_VERSION%.*}"
CONTAINERD_VERSION="2.0.3"

# Exit script on any error
set -e

# Determine platform architecture
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

# Check and remove old Kubernetes versions
cleanup_old_k8s() {
  echo "[Cleanup] Removing old Kubernetes installations..."
  echo
  sudo kubeadm reset -f || true
  sudo apt-get remove -y kubelet kubeadm kubectl || true
  sudo apt-get autoremove -y || true
  sudo rm -rf ~/.kube /etc/kubernetes /var/lib/etcd /var/lib/kubelet
  echo "[Cleanup] Old Kubernetes installations removed."
}

# Update system packages
update_system() {
  echo "[System] Updating system packages..."
  sudo apt-get update && sudo apt-get upgrade -y
  echo "[System] System update complete."
}

# Install Podman
install_podman() {
  echo "[Podman] Installing Podman..."
  sudo apt-get install -y podman
  echo "[Podman] Podman installed."
}

# Install Kubernetes
install_kubernetes() {
  echo "[Kubernetes] Adding Kubernetes repository..."
  echo
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_MAJOR_MINOR}/deb/Release.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-${K8S_VERSION_MAJOR_MINOR/./-}-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-${K8S_VERSION_MAJOR_MINOR/./-}-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_MAJOR_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
  sudo apt-get update
  echo
  echo "[Kubernetes] Installing kubeadm, kubelet, and kubectl version $K8S_VERSION..."
  echo
  sudo apt-get install -y kubelet=${K8S_VERSION}-1.1 kubeadm=${K8S_VERSION}-1.1 kubectl=${K8S_VERSION}-1.1
  sudo apt-mark hold kubelet kubeadm kubectl
  echo "[Kubernetes] Kubernetes installation complete."
}

# Disable linux swap and remove any exisitng swap partitions
disable_swap() {
  swapoff -a
  sed -i '/\sswap\s/ s/^\(.*\)$/#\1/g' /etc/fstab
}

# Install containerd
install_containerd() {
  echo "[Containerd] Installing containerd..."
  echo
  wget https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${PLATFORM}.tar.gz
  tar xvf containerd-${CONTAINERD_VERSION}-linux-${PLATFORM}.tar.gz
  systemctl stop containerd
  mv bin/* /usr/bin
  rm -rf bin containerd-${CONTAINERD_VERSION}-linux-${PLATFORM}.tar.gz
  systemctl unmask containerd
  systemctl start containerd
  echo "[Containerd] Containerd installed."
}

# Setup containerd environmet
setup_containerd() {
  echo "[Containerd] Setting up containerd environment..."
  echo
  cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
  sudo modprobe overlay
  sudo modprobe br_netfilter
  cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
  sudo sysctl --system
  sudo mkdir -p /etc/containerd
  echo "[Containerd] Containerd environment setup completed."
}

# Create custom containerd configure file
create_containerd_config() {
  echo '[Containerd] Creating containerd config...'
  echo
  cat > /etc/containerd/config.toml <<EOF
disabled_plugins = []
imports = []
oom_score = 0
plugin_dir = ""
required_plugins = []
root = "/var/lib/containerd"
state = "/run/containerd"
version = 2

[plugins]

  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
      base_runtime_spec = ""
      container_annotations = []
      pod_annotations = []
      privileged_without_host_devices = false
      runtime_engine = ""
      runtime_root = ""
      runtime_type = "io.containerd.runc.v2"

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
        BinaryName = ""
        CriuImagePath = ""
        CriuPath = ""
        CriuWorkPath = ""
        IoGid = 0
        IoUid = 0
        NoNewKeyring = false
        NoPivotRoot = false
        Root = ""
        ShimCgroup = ""
        SystemdCgroup = true
EOF
  echo "[Containerd] containerd config created successfully."
}

# Configure crictl to use containerd as default
configure_crictl() {
  echo "[Crictl] Enable crictl to use containerd as default..."
  echo
  {
    cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
EOF
  }
  echo "[Crictl] crictl configured successfully."
}

# Configure kubelet to use containerd as default
configure_kubelet() {
  echo "[Kubelet] Enable kubelet to use containerd as default..."
  echo
  {
    cat <<EOF | sudo tee /etc/default/kubelet
KUBELET_EXTRA_ARGS="--container-runtime-endpoint unix:///run/containerd/containerd.sock"
EOF
  }
  echo "[Kubelet] kubelet configured successfully."
}

# Start containerd and kubelet services
start_services() {
  echo "[System] Starting containerd and kubelet services..."
  echo
  kubeadm reset -f
  systemctl daemon-reload
  systemctl enable containerd
  systemctl restart containerd
  systemctl enable kubelet && systemctl start kubelet
  echo "[System] Services started successfully."
}

# Update shell environment
configure_shell() {
  echo "[Configuration] Updating .bashrc and .vimrc..."
  echo 'colorscheme ron' >> ~/.vimrc
  echo 'set tabstop=2' >> ~/.vimrc
  echo 'set shiftwidth=2' >> ~/.vimrc
  echo 'set expandtab' >> ~/.vimrc
  echo '' >> ~/.bashrc
  echo '# Kubernetes' >> ~/.bashrc
  echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc
  echo 'source <(kubectl completion bash)' >> ~/.bashrc
  echo 'alias k='kubectl'' >> ~/.bashrc
  echo 'alias c='clear'' >> ~/.bashrc
  echo 'complete -F __start_kubectl k' >> ~/.bashrc
  sed -i '1s/^/force_color_prompt=yes\n/' ~/.bashrc
  echo "[Configuration] Shell environment updated."
}

# Run installation steps
check_architecture
cleanup_old_k8s
update_system
install_podman
install_kubernetes
disable_swap
install_containerd
setup_containerd
create_containerd_config
configure_crictl
configure_kubelet
start_services
configure_shell

# Final message
echo "[Setup Complete] Kubernetes worker node setup finished successfully!"