#!/bin/bash

# Define variables
K8S_VERSION="1.32.2"
K8S_VERSION_MAJOR_MINOR="${K8S_VERSION%.*}"
CNI_VERSION="v1.2.0"
CALICO_VERSION="v3.26.1"
CONTAINERD_VERSION="2.0.3"
ETCDCTL_VERSION="v3.5.1"
POD_NETWORK_CIDR="192.168.0.0/16"

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
  kubeadm reset -f || true
  echo "[Cleanup] Removing containerd pods..."
  crictl rm --force $(crictl ps -a -q) || true
  echo "[Cleanup] Unholding packages..."
  apt-mark unhold kubelet kubeadm kubectl kubernetes-cni || true
  echo "[Cleanup] Removing packages..."
  apt-get remove -y docker.io containerd kubelet kubeadm kubectl kubernetes-cni || true
  echo "[Cleanup] Removing autoremovable packages..."
  apt-get autoremove -y || true
  echo "[Cleanup] Removing directories..."
  rm -rf ~/.kube /etc/kubernetes /var/lib/etcd /var/lib/kubelet
  echo "[Cleanup] Old Kubernetes installations removed."
}

# Install dependencies
install_dependencies() {
  echo "[Dependencies] Installing required packages..."
  apt-get install -y apt-transport-https ca-certificates curl gpg software-properties-common vim bash-completion
  echo "[Dependencies] Packages installed."
}

# Install Kubernetes
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
  systemctl daemon-reload
  systemctl enable containerd
  systemctl restart containerd
  systemctl enable kubelet && systemctl start kubelet
  echo "[System] Services started successfully."
}

# Initialize the Kubernetes cluster
initialize_kubernetes() {
  echo "[Kubernetes] Initializing Kubernetes cluster..."
  echo "[Kubernetes] Running kubeadm init..."
  kubeadm init --ignore-preflight-errors=NumCPU --pod-network-cidr=${POD_NETWORK_CIDR} --kubernetes-version=${K8S_VERSION} 2>&1 | tee kubeadm-init.log
  echo "[Kubernetes] kubeadm init completed."
  echo "[Kubernetes] Setting up kubectl for the current user..."
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  echo "[Kubernetes] kubectl configured successfully."
  echo "[Kubernetes] Applying Calico CNI plugin..."
  curl -fsSL -o calico.yaml https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml
  echo "[Kubernetes] Running kubectl to apply Calico CNI plugin..."
  kubectl apply -f calico.yaml
  echo "[Kubernetes] Calico networking configured."
}

# Setup etcdctl
setup_etcdctl() {
  echo "[Etcdctl] Downloading etcdctl..."
  ETCDCTL_ARCH=$(dpkg --print-architecture)
  ETCDCTL_VERSION_FULL="etcd-${ETCDCTL_VERSION}-linux-${ETCDCTL_ARCH}"
  wget -q -O ${ETCDCTL_VERSION_FULL}.tar.gz https://github.com/etcd-io/etcd/releases/download/${ETCDCTL_VERSION}/${ETCDCTL_VERSION_FULL}.tar.gz
  echo "[Etcdctl] Downloaded ${ETCDCTL_VERSION_FULL}.tar.gz"
  echo "[Etcdctl] Extracting etcdctl..."
  tar xzf ${ETCDCTL_VERSION_FULL}.tar.gz ${ETCDCTL_VERSION_FULL}/etcdctl
  echo "[Etcdctl] Extracted ${ETCDCTL_VERSION_FULL}/etcdctl"
  echo "[Etcdctl] Moving etcdctl to /usr/bin..."
  sudo mv ${ETCDCTL_VERSION_FULL}/etcdctl /usr/bin/
  echo "[Etcdctl] Moved etcdctl to /usr/bin/"
  echo "[Etcdctl] Cleaning up temporary files..."
  rm -rf ${ETCDCTL_VERSION_FULL} ${ETCDCTL_VERSION_FULL}.tar.gz
  echo "[Etcdctl] Temporary files cleaned up."
  echo "[Etcdctl] Installation complete."
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

# Output the join command for worker nodes
output_join_command() {
  echo "[Kubernetes] Fetching join command for worker nodes..."
  echo
  kubeadm token create --print-join-command --ttl 0 | tee kubeadm-join-command.txt
  echo
  echo "[Kubernetes] Join command saved in kubeadm-join-command.txt"
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
setup_etcdctl
configure_shell
output_join_command

# Final message
echo "[Setup Complete] Kubernetes master node setup finished successfully!"