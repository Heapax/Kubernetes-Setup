#!/bin/bash

K8S_VERSION=v1.32
K8S_VERSION_OLD=v1.31
K8S_GPG_VERSION=1-32
K8S_GPG_VERSION_OLD=1-31
KUBE_VERSION=1.32.2
CONTAINERD_VERSION=1.6.12
CALICO_VERSION=v3.29.2
ETCDCTL_VERSION=v3.5.16


### get platform
PLATFORM=`uname -p`

if [ "${PLATFORM}" == "aarch64" ]; then
  PLATFORM="arm64"
elif [ "${PLATFORM}" == "x86_64" ]; then
  PLATFORM="amd64"
else
  echo "${PLATFORM} has to be either amd64 or arm64/aarch64. Check containerd supported binaries page"
  echo "https://github./containerd/containerd/blob/main/docs/getting-started.md#option-1-from-the-official-binaries"
  exit 1
fi


### setup terminal
echo
echo 'Setting up terminal environment...'
echo
apt-get --allow-unauthenticated update
apt-get --allow-unauthenticated install -y bash-completion binutils
echo 'colorscheme ron' >> ~/.vimrc
echo 'set tabstop=2' >> ~/.vimrc
echo 'set shiftwidth=2' >> ~/.vimrc
echo 'set expandtab' >> ~/.vimrc
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'alias c=clear' >> ~/.bashrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc
sed -o '1s/^/force_color_prompt=yes\n/' ~/.bashrc


### disable linux swap and remove any exisitng swap partitions
echo
echo 'Disabling Linux swap and remove existing swap partitions...'
echo
swapoff -a
sed -i '/\sswap\s/ s/^\(.*\)$/#\1/g' /etc/fstab

### remove packages
echo
echo 'Removing old install files...'
echo
kubeadm reset -f || true
crictl rm --force $(circtl ps -a -q) || true
apt-mark unhold kubelet kubeadm kubectl kubernetes-cni || true
apt-get remove -y docker.io containerd kubelet kubeadm kubectl kubernetes-cni || true
apt-get autoremove -y
systemctl daemon-reload


### install podman
echo
echo 'Installing podman cri...'
echo
. /etc/os-release
echo "deb http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:testing.list
curl -L "http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/Release.key" | sudo apt-key add -
apt-get update -qq
apt-get -qq -y install podman cri-tools containers-common
rm /etc/apt/sources.list.d/devel:kubic:libcontainers:testing.list
cat <<EOF | sudo tee /etc/containers/registries.conf
[registries.search]
registries = ['docker.io']
EOF


### install packages
echo
echo 'Installing packages...'
echo
apt-get insatll -y apt-transport-https ca-certificates
mkdir -p /etc/apt/keyrings
rm /etc/apt/keyrings/kubernetes-${K8S_GPG_VERSION}-apt-keyring.gpg || true
rm /etc/apt/keyrings/kubernetes-${K8S_GPG_VERSION_OLD}-apt-keyring.gpg || true
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-1-31-apt-keyring.gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION_OLD}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-1-30-apt-keyring.gpg
echo > /etc/apt/source.list.d/kubernetes.list
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-${K8S_GPG_VERSION}-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb /" | sudo tee -a /etc/apt/source.list.d/kubernetes.list
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-${K8S_GPG_VERSION_OLD}-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION_OLD}/deb /" | sudo tee -a /etc/apt/source.list.d/kubernetes.list
apt-get --allow-unauthenticated update
apt-get --allow-unauthenticated install -y docker.io containerd kubelet=${KUBE_VERSION}-1.1 kubeadm=${KUBE_VERSION}-1.1 kubectl=${KUBE_VERSION}-1.1 kubernetes-cni
apt-mark hold kubelet kubeadm kubectl kubernetes-cni


### install containerd 1.6 over apt-installed-version
echo
echo 'Installing cotainerd version ${CONTAINERD_VERSION}...'
echo
wget https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${PLATFORM}.tar.gz
tar xvf containerd-${CONTAINERD_VERSION}-linux-${PLATFORM}.tar.gz
systemctl stop containerd
mv bin/* /usr/bin
rm -rf bin containerd-${CONTAINERD_VERSION}-linux-${PLATFORM}.tar.gz
systemctl unmask containerd
systemctl start containerd


### containerd
echo
echo 'Setting up environment for contaienrd...'
echo
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfiler
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system
sudo mkdir -p /etc/containerd


### containerd config
echo
echo 'Creating containerd config...'
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


### crictl uses containerd as default
echo
echo 'Enable crictl to use contaienrd as default...'
echo
{
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
EOF
}


### kubelet should use containerd
echo
echo 'Enable kubelet to use containerd as default...'
echo
{
cat <<EOF | sudo tee /etc/default/kubelet
KUBELET_EXTRA_ARGS="--container-runtime-endpoint unix:///run/containerd/containerd.sock"
EOF
}


### start services
echo
echo 'Starting containerd and kubelet services:'
echo
systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd
systemctl enable kubelet && systemctl start kubelet


### init k8s
echo
echo 'Initializing kubernetes:'
echo
rm /root/.kube/config || true
kubeadm init --kubernetes-version=${KUBE_VERSION} --ignore-preflight-errors=NumCPU --skip-token-print --pod-network-cidr 192.168.0.0/16

mkdir -p ~/.kube
sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config


### CNI
echo
echo 'Installing calico networking plugin:'
echo
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml


### etcdctl
echo
echo 'Configuring etcdctl:'
echo
ETCDCTL_ARCH=$(dpkg --print-architecture)
ETCDCTL_VERSION_FULL=etcd-${ETCDCTL_VERSION}-linux-${ETCDCTL_ARCH}
wget https://github.com/etcd-io/etcd/releases/download/${ETCDCTL_VERSION}/${ETCDCTL_VERSION_FULL}.tar.gz
tar xzf ${ETCDCTL_VERSION_FULL}.tar.gz ${ETCDCTL_VERSION_FULL}/etcdctl
mv ${ETCDCTL_VERSION_FULL}/etcdctl /usr/bin/
rm -rf ${ETCDCTL_VERSION_FULL} ${ETCDCTL_VERSION_FULL}.tar.gz

echo
echo "### COMMAND TO ADD A WORKER NODE ###"
kubeadm token create --print-join-command --ttl 0