#!/bin/bash

### Dynamic vars (from terraform)

DATA_DIR_NAME=data
# shellcheck disable=SC2154
CONTROLLER_JOIN_TOKEN=${controller_join_token}
# shellcheck disable=SC2154
IS_WORKER=${is_worker}
# shellcheck disable=SC2154
CLUSTER_ID=${cluster_id}
# shellcheck disable=SC2154
AWS_REGION=${region}
# shellcheck disable=SC2154
K8S_DEB_PACKAGES_VERSION=${k8s_deb_package_version}
# shellcheck disable=SC2154
KUBEADM_VERSION_OF_K8S_TO_INSTALL=${kubeadm_install_version}

### Statics

echo "START: $(date)" >> /opt/bootstrap_times

AWS_HOSTNAME=$(curl http://169.254.169.254/latest/meta-data/local-hostname)
hostname "$AWS_HOSTNAME"
echo "$AWS_HOSTNAME" > /etc/hostname
echo "127.0.0.1 $AWS_HOSTNAME" >> /etc/hosts

export DEBIAN_FRONTEND="noninteractive"

apt-get update
apt-get upgrade --assume-yes
apt-get autoremove --assume-yes
apt-get clean

locale-gen en_GB.UTF-8 # Will fix the warning when logging to the box

################################################# If it has drives

# Format drive if present
ISFORMATTED=$(file -s /dev/xvdi | grep -c '/dev/xvdi: data')
if [[ "$ISFORMATTED" == '1'  ]]
then
  mkfs -t ext4 /dev/xvdi
fi

# Mount drive if present
ISFORMATTED=$(file -s /dev/xvdi | grep -c 'ext4 filesystem data')
if [[ $ISFORMATTED == '1'  ]]
then
  mkdir /opt/$DATA_DIR_NAME
  cp /etc/fstab /etc/fstab.orig
  echo "/dev/xvdi       /opt/$DATA_DIR_NAME      ext4     data=writeback,relatime,nobarrier        0 0" >> /etc/fstab
  mount -a
fi

#################################################

# Add repo
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat << EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF

# You need nfs-common to use efs
apt update
apt install -y \
  docker.io \
  apt-transport-https \
  awscli \
  jq \
  curl \
  nfs-common
# This need to be synched
apt install -y \
  kubelet="$K8S_DEB_PACKAGES_VERSION-00" \
  kubeadm="$K8S_DEB_PACKAGES_VERSION-00" \
  kubectl="$K8S_DEB_PACKAGES_VERSION-00"

# Hold these packages back so that we don't accidentally upgrade them.
# TODO: Remove version (locking to avoid bug in kubeadm)
apt-mark hold kubelet kubeadm kubectl kubernetes-cni

# Set new memory limit container with high memory requirements
sysctl -w vm.max_map_count=262144

## Configure docker deamon
# From https://kubernetes.io/docs/setup/production-environment/container-runtimes/
# Solves [WARNING IsDockerSystemdCheck]: detected "cgroupfs" as the Docker cgroup driver. The recommended driver is "systemd".
cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
systemctl daemon-reload
systemctl restart docker
# Avoids [WARNING Service-Docker]: docker service is not enabled, please run 'systemctl enable docker.service'
systemctl enable docker.service

echo 'KUBELET_EXTRA_ARGS=--cloud-provider=aws' > /etc/default/kubelet

# Adding autocomplete for ubuntu
echo 'source <(kubectl completion bash)' > /etc/bash_completion.d/kubectl

if [[ "x"$IS_WORKER == "x" ]]
then
  # Start as master (no HA)
  # Forcing version
  VERSION=$KUBEADM_VERSION_OF_K8S_TO_INSTALL
  kubeadm init \
    --kubernetes-version "$VERSION" \
    --token "$CONTROLLER_JOIN_TOKEN"
  KCTL_USER='ubuntu'
  cd /home/$KCTL_USER || exit
  mkdir -p /home/$KCTL_USER/.kube
  sudo cp -i /etc/kubernetes/admin.conf /home/$KCTL_USER/.kube/config
  sudo chown "$KCTL_USER":"$KCTL_USER" -R /home/$KCTL_USER/.kube
  echo "export KUBECONFIG=/home/$KCTL_USER/.kube/config" | tee -a /home/$KCTL_USER/.bashrc
  su "$KCTL_USER" -c "kubectl label --overwrite no $AWS_HOSTNAME node-role.kubernetes.io/master=true"
  # Install CNI plugin
  su "$KCTL_USER" -c "kubectl apply -f https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
else
  # You need to filter by tag Name to find the master to connect to. You don't
  # know at startup time the ip.
  MASTER_IP=$(aws ec2 describe-instances --filters "Name=tag:k8s.io/role/master,Values=1" "Name=tag:KubernetesCluster,Values=$CLUSTER_ID" --region="$AWS_REGION" | grep '\"PrivateIpAddress\"' | cut -d ':' -f2 | cut -d'"' -f 2 | uniq)
  # Read gotchas #1
  echo "Connecting to $MASTER_IP port 6443"
  echo "Connecting with token $CONTROLLER_JOIN_TOKEN"
  kubeadm join \
    --discovery-token-unsafe-skip-ca-verification \
    --token "$CONTROLLER_JOIN_TOKEN" \
    "$MASTER_IP:6443"
fi

touch /opt/bootstrap_completed
echo "END: $(date)" >> /opt/bootstrap_times
