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
  echo "[System] Uname -m output: $(uname -m)"
  ARCH=$(uname -m)
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

# Disable linux swap and remove any exisitng swap partitions
disable_swap() {
  echo "[System] Disabling swap space and removing swap partitions..."
  swapoff -a
  sed -i '/\sswap\s/ s/^\(.*\)$/#\1/g' /etc/fstab
  echo "[System] Swap space disabled."
}

# Check and remove old Kubernetes versions
cleanup_old_k8s() {
  echo "[Cleanup] Removing old Kubernetes installations..."
  echo "[Cleanup] Running kubeadm reset..."
  sudo kubeadm reset -f || true
  echo "[Cleanup] Removing packages..."
  sudo apt-get remove -y kubelet kubeadm kubectl || true
  echo "[Cleanup] Removing autoremovable packages..."
  sudo apt-get autoremove -y || true
  echo "[Cleanup] Removing directories..."
  sudo rm -rf ~/.kube /etc/kubernetes /var/lib/etcd /var/lib/kubelet
  echo "[Cleanup] Old Kubernetes installations removed."
}

# Install dependencies
install_dependencies() {
  echo "[Dependencies] Installing required packages..."
  apt-get install -y apt-transport-https ca-certificates curl gpg software-properties-common vim bash-completion
  echo "[Dependencies] Packages installed."
}

install_kubernetes() {
  echo "[Kubernetes] Starting installation process..."
  echo "[Kubernetes] Adding Kubernetes repository..."
  mkdir -p /etc/apt/keyrings
  KEYRING_PATH="/etc/apt/keyrings/kubernetes-${K8S_VERSION_MAJOR_MINOR/./-}-apt-keyring.gpg"
  if [ -f "$KEYRING_PATH" ]; then
    echo "[Kubernetes] Existing keyring found, removing..."
    rm "$KEYRING_PATH"
  fi
  echo "[Kubernetes] Downloading and installing keyring..."
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_MAJOR_MINOR}/deb/Release.key | sudo gpg --dearmor --yes -o "$KEYRING_PATH"
  echo "[Kubernetes] Adding Kubernetes to sources list..."
  echo "deb [signed-by=$KEYRING_PATH] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_MAJOR_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
  echo "[Kubernetes] Updating package list..."
  apt-get update
  echo "[Kubernetes] Installing packages..."
  apt-get install -y docker.io containerd kubelet=${K8S_VERSION}-1.1 kubeadm=${K8S_VERSION}-1.1 kubectl=${K8S_VERSION}-1.1
  echo "[Kubernetes] Holding package versions..."
  apt-mark hold kubelet kubeadm kubectl kubernetes-cni
  echo "[Kubernetes] Kubernetes installation complete."
}

# Install containerd
# Install containerd
install_containerd() {
  echo "[Containerd] Installing containerd..."
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
  kubeadm reset -f
  systemctl daemon-reload
  systemctl enable containerd
  systemctl restart containerd
  systemctl enable kubelet && systemctl start kubelet
  echo "[System] Services started successfully."
}

# Initialize kubernetes
initialize_kubernetes() {
  echo "[Kubernetes] Initializing Kubernetes cluster..."
  echo "[Kubernetes] Running kubeadm reset..."
  kubeadm reset -f
  echo "[Kubernetes] kubeadm reset completed."
  echo "[Kubernetes] Reloading systemd daemon..."
  systemctl daemon-reload
  echo "[Kubernetes] Systemd daemon reloaded."
  echo "[Kubernetes] Starting kubelet service..."
  systemctl start kubelet
  echo "[Kubernetes] kubelet service started."
  echo "[Kubernetes] Kubernetes initialization complete."
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
disable_swap
cleanup_old_k8s
install_dependencies
install_kubernetes
install_containerd
setup_containerd
create_containerd_config
configure_crictl
configure_kubelet
start_services
initialize_kubernetes
configure_shell

# Final message
echo "[Setup Complete] Kubernetes worker node setup finished successfully!"