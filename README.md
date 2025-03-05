# Before running the script

1. Set the hostname for each control-plane and worker node using `hostnamectl set-hostname`.
  - e.g. Use `sudo hostctl set-hostname k8s-control` for the control-plane node.
  - Note: Exit and log back in to each for the changes to take effect.
2. Update `/etc/hosts` on each control-plane and worker node with the IP addresses and hostnames given to each node.
  - e.g. An entry might look like this: `172.16.0.0 k8s-control`, do this for every node on every node.
  - Note: Use a the Private IP addresses of the nodes, public IPs might change!

# How to use

Enter the following commands into the master nodes and worker nodes respectivly:

Master:
```sh
sudo bash <(curl -s https://raw.githubusercontent.com/Heapax/Kubernetes-Setup/refs/heads/main/new_master_setup.sh)
```

Worker:
```sh
sudo bash <(curl -s https://raw.githubusercontent.com/Heapax/Kubernetes-Setup/refs/heads/main/new_worker_setup.sh)
```

> Note: This script has been tested on Ubuntu 22.04 - Jammy Jellyfish.