---
title: "Building a vanilla Kubernetes cluster"
description: "Building a minimal Kubernetes cluster by hand from the official binaries: certificates, kubeconfigs, etcd, control plane and workers on three openSUSE nodes"
tags: [kubernetes, cluster-setup, etcd, certificates, keepalived, containerd, opensuse]
type: lab
status: complete
---

# Building a vanilla Kubernetes cluster

> [!info] My own lab, not derived from the course
> This is original material: a "Kubernetes the hard way" style build on three
> openSUSE Leap VMs, with keepalived providing the API virtual address. It exists to
> make the moving parts concrete — compare
> [[kubernetes/cluster-setup/dmuc-easy]] for the course's own take on the same idea.

> [!warning] Not a production deployment
> Everything here is done by hand on purpose, so nothing is hidden. For a real
> cluster use kubeadm, RKE2, k0s or a managed service: they get the certificate
> rotation, upgrades and etcd backups right, and those are exactly the parts this lab
> skips. See [[kubernetes/cluster-setup/setup-overview]].

> [!important] Versions
> Kubernetes 1.36.2, containerd 2.2.5, runc 1.3.6, etcd 3.6.6, CNI plugins 1.9.1,
> crictl 1.35.0, cfssl 1.6.5, CoreDNS 1.14.6.
>
> Some command **outputs** come from a Kubernetes 1.21 run and are illustrative: pod
> names, ages and hashes will differ.

> [!note] Partly tested
> The whole build was tested on Leap 16 with Kubernetes 1.36.2. Three containers with
> systemd and sshd stood in for the VMs, on 10.240.1.0/24, from the certificates to
> CoreDNS and a Deployment reachable from every node. Not tested: keepalived (a static
> second address stood in for the virtual IP), `swapoff` (the containers share the
> Docker VM's swap, so the test set `failSwapOn: false` instead), and the proxy settings.

We are going to put what we have seen into practice by building a **vanilla** Kubernetes cluster — that is, directly from the project's binaries.

The goal is a minimal cluster built on the official Kubernetes binaries. Nothing here is hidden behind an installer, which is the point: every certificate, every flag and every unit file is written by hand.

## Our environment

Three openSUSE Leap 16 virtual machines (the lab was first built on Leap 15):

- `k8s-01` — 10.240.1.31
- `k8s-02` — 10.240.1.32
- `k8s-03` — 10.240.1.33

And a virtual address shared between them:

- `k8s-api` — 10.240.1.30

## Installing keepalived

The cluster must be able to reach **kube-apiserver** at all times. For that you can use:

- a load balancer provided by your cloud provider
- an external load balancer
- keepalived

In this lab we use the last option, to avoid deploying another server.

```bash
zypper install -y keepalived
```

The first node will be *master* and so gets a higher *priority* (a weight).

```bash
cat > /etc/keepalived/keepalived.conf <<EOF
vrrp_instance VI_1 {

   state MASTER
   priority 255
   virtual_router_id 100
   advert_int 1
   interface eth0
   authentication {
           auth_type PASS
           auth_pass 12345
   }
   virtual_ipaddress {
        10.240.1.30/24
   }
}
EOF
```

The other nodes are *backup*, and so get a lower *priority*:

```bash
cat > /etc/keepalived/keepalived.conf <<EOF
vrrp_instance VI_1 {

   state BACKUP
   priority 100
   virtual_router_id 100
   advert_int 1
   interface eth0
   authentication {
           auth_type PASS
           auth_pass 12345
   }
   virtual_ipaddress {
        10.240.1.30/24
   }
}
EOF
```

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} systemctl enable --now keepalived.service
done
```

## Installing the binaries

On a SUSE OS you can install supported builds of runc and containerd directly:

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} zypper install -y apparmor-parser runc containerd
done
```

Installing the latest version of:

- the **container runtime**, **containerd**, with its runc shim
- containerd's own CLI, **ctr** (the CRI CLI is `crictl`, installed below)

```bash
CONTAINERD_VER=2.2.5
DOWNLOAD_URL=https://github.com/containerd/containerd/releases/download

rm -f /tmp/containerd-linux-amd64.tar.gz
rm -rf /tmp/containerd && mkdir -p /tmp/containerd

curl -fL ${DOWNLOAD_URL}/v${CONTAINERD_VER}/containerd-${CONTAINERD_VER}-linux-amd64.tar.gz -o /tmp/containerd-linux-amd64.tar.gz
tar xzvf /tmp/containerd-linux-amd64.tar.gz -C /tmp/containerd
rm -f /tmp/containerd-linux-amd64.tar.gz

install -o root -g root -m 0755 /tmp/containerd/bin/containerd /usr/local/bin/containerd
install -o root -g root -m 0755 /tmp/containerd/bin/containerd-shim-runc-v2 /usr/local/bin/containerd-shim-runc-v2
install -o root -g root -m 0755 /tmp/containerd/bin/ctr /usr/local/bin/ctr

curl -fL https://raw.githubusercontent.com/containerd/containerd/main/containerd.service -o /etc/systemd/system/containerd.service
systemctl daemon-reload
systemctl enable --now containerd
```

> [!warning] Install `containerd-shim-runc-v2`
> Without it, every pod stays in `ContainerCreating`, with `failed to start shim: ...
> binary not installed "containerd-shim-runc-v2"`. `ctr` talks to containerd
> directly; the CRI CLI is `crictl`.

The latest stable **runc**:

```bash
RUNC_VER=v1.3.6
DOWNLOAD_URL=https://github.com/opencontainers/runc/releases/download

rm -f /tmp/runc

curl -fL ${DOWNLOAD_URL}/${RUNC_VER}/runc.amd64 -o /tmp/runc

install -o root -g root -m 0755 /tmp/runc /usr/local/bin/runc
```

The latest stable **Kubernetes** binaries:

```bash
KUBERNETES_VER=v1.36.2
DOWNLOAD_URL=https://dl.k8s.io

rm -f /tmp/kubernetes-server-linux-amd64.tar.gz
rm -rf /tmp/kubernetes && mkdir -p /tmp/kubernetes

curl -fL ${DOWNLOAD_URL}/${KUBERNETES_VER}/kubernetes-server-linux-amd64.tar.gz -o /tmp/kubernetes-server-linux-amd64.tar.gz
tar xzvf /tmp/kubernetes-server-linux-amd64.tar.gz -C /tmp
rm -f /tmp/kubernetes-server-linux-amd64.tar.gz

install -o root -g root -m 0755 /tmp/kubernetes/server/bin/kubectl /usr/local/bin/kubectl
install -o root -g root -m 0755 /tmp/kubernetes/server/bin/kube-apiserver /usr/local/bin/kube-apiserver
install -o root -g root -m 0755 /tmp/kubernetes/server/bin/kube-scheduler /usr/local/bin/kube-scheduler
install -o root -g root -m 0755 /tmp/kubernetes/server/bin/kube-controller-manager /usr/local/bin/kube-controller-manager
install -o root -g root -m 0755 /tmp/kubernetes/server/bin/kube-proxy /usr/local/bin/kube-proxy
install -o root -g root -m 0755 /tmp/kubernetes/server/bin/kubelet /usr/local/bin/kubelet
```

> [!warning] No trailing slash
> With `DOWNLOAD_URL=https://dl.k8s.io/`, the URLs get a `//`. `dl.k8s.io` answers 404
> to that, and `curl -L` without `-f` saves the error page as the tarball: `tar` then
> fails with "not in gzip format". All `curl` commands here use `-f`, so a failed
> download stops there.

The latest stable **crictl**:

```bash
CRICTL_VER=v1.35.0
DOWNLOAD_URL=https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VER}/crictl-${CRICTL_VER}-linux-amd64.tar.gz

rm -f /tmp/crictl-${CRICTL_VER}-linux-amd64.tar.gz
rm -rf /tmp/crictl

curl -fL ${DOWNLOAD_URL} -o /tmp/crictl-${CRICTL_VER}-linux-amd64.tar.gz
tar xzvf /tmp/crictl-${CRICTL_VER}-linux-amd64.tar.gz -C /tmp
rm -f /tmp/crictl-${CRICTL_VER}-linux-amd64.tar.gz

install -o root -g root -m 0755 /tmp/crictl /usr/local/bin/crictl
```

The latest stable **cni-plugins**:

```bash
CNI_PLUGINS_VER=v1.9.1
DOWNLOAD_URL=https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VER}/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz

rm -f /tmp/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz
mkdir -p /opt/cni/bin/

curl -fL ${DOWNLOAD_URL} -o /tmp/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz
tar xzvf /tmp/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz -C /opt/cni/bin/
rm -f /tmp/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz
```

The latest stable **etcd**:

```bash
ETCD_VER=v3.6.6
DOWNLOAD_URL=https://github.com/etcd-io/etcd/releases/download

rm -f /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz
rm -rf /tmp/etcd-download-test && mkdir -p /tmp/etcd-download-test

curl -fL ${DOWNLOAD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar xzvf /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz -C /tmp/etcd-download-test --strip-components=1
rm -f /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz

install -o root -g root -m 0755 /tmp/etcd-download-test/etcd /usr/local/bin/etcd
install -o root -g root -m 0755 /tmp/etcd-download-test/etcdctl /usr/local/bin/etcdctl
```

The latest stable **cfssl**, to make generating our certificates easier:

```bash
CFSSL_VER=1.6.5
DOWNLOAD_URL=https://github.com/cloudflare/cfssl/releases/download

rm -f /tmp/cfssl_${CFSSL_VER}_linux_amd64
rm -rf /tmp/cfssl && mkdir -p /tmp/cfssl

curl -fL ${DOWNLOAD_URL}/v${CFSSL_VER}/cfssl_${CFSSL_VER}_linux_amd64 -o /tmp/cfssl/cfssl
curl -fL ${DOWNLOAD_URL}/v${CFSSL_VER}/cfssljson_${CFSSL_VER}_linux_amd64 -o /tmp/cfssl/cfssljson

install -o root -g root -m 0755 /tmp/cfssl/cfssl /usr/local/bin/cfssl
install -o root -g root -m 0755 /tmp/cfssl/cfssljson /usr/local/bin/cfssljson
```

Checking what we installed:

```bash
containerd --version
  containerd github.com/containerd/containerd/v2 v2.2.5 ...

ctr --version
  ctr github.com/containerd/containerd/v2 v2.2.5

kubectl version --client
  Client Version: v1.36.2
  ...

kube-apiserver --version
  Kubernetes v1.36.2

etcd --version
  etcd Version: 3.6.6
  ...

etcdctl version
  etcdctl version: 3.6.6
  ...

crictl --version
  crictl version v1.35.0

cfssl version
  Version: 1.6.5
  ...
```

## Environment variables

Several variables are used when generating the various configuration files.
For production with an automated deployment — kubeadm, Ansible — this would not be necessary:

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} echo 'ETCD_PUBLIC_ADDRESS=`ip -4 addr show eth0 | grep -v secondary | grep -oP "(?<=inet\s)\d+(\.\d+){3}"` >> /etc/environment'
ssh ${instance} echo 'ETCD_NAME=$(hostname -s) >> /etc/environment'
ssh ${instance} echo 'KUBELET_NAME=$(hostname -s) >> /etc/environment'
ssh ${instance} echo 'DOMAIN=internal.example.com >> /etc/environment'
ssh ${instance} echo 'KUBERNETES_PUBLIC_ADDRESS=`ip -4 addr show eth0 | grep -v secondary | grep -oP "(?<=inet\s)\d+(\.\d+){3}"` >> /etc/environment'
ssh ${instance} echo 'KUBERNETES_VIP_ADDRESS=`ip -4 addr show eth0 | grep secondary | grep -oP "(?<=inet\s)\d+(\.\d+){3}"` >> /etc/environment'
ssh ${instance} echo 'KUBERNETES_HOSTNAMES=kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,kubernetes.svc.cluster.local,k8s-01.internal.example.com,k8s-02.internal.example.com,k8s-03.internal.example.com,k8s-01,k8s-02,k8s-03,k8s-api.internal.example.com,k8s-api >> /etc/environment'
done
```

## Generating the certificates

Create the directory that will hold the certificates:

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} mkdir /opt/certs
done
```

### The certificate authority

```bash
cat > /opt/certs/ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

cat > /opt/certs/ca-csr.json <<EOF
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "FR",
      "L": "Example City",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Example State"
    }
  ]
}
EOF

cfssl gencert -initca /opt/certs/ca-csr.json | cfssljson -bare /opt/certs/ca
```

Our CA is generated:

```bash
ls /opt/certs/ |grep ca
  ca-config.json
  ca-csr.json
  ca-key.pem
  ca.csr
  ca.pem
```

### The client certificate for the admin user

```bash
cat > /opt/certs/admin-csr.json <<EOF
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "FR",
      "L": "Example City",
      "O": "system:masters",
      "OU": "Kubernetes The Hard Way",
      "ST": "Example State"
    }
  ]
}
EOF

cfssl gencert \
  -ca=/opt/certs/ca.pem \
  -ca-key=/opt/certs/ca-key.pem \
  -config=/opt/certs/ca-config.json \
  -profile=kubernetes \
  /opt/certs/admin-csr.json | cfssljson -bare /opt/certs/admin
```

```bash
ls /opt/certs/ |grep admin
  admin-csr.json
  admin-key.pem
  admin.csr
  admin.pem
```

### The kubelet certificates

Next we generate the certificates for the **kubelet** on each *worker* node:

```bash
for instance in k8s-0{1,2,3}; do
cat > /opt/certs/${instance}-csr.json <<EOF
{
  "CN": "system:node:${instance}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "FR",
      "L": "Example City",
      "O": "system:nodes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Example State"
    }
  ]
}
EOF
done
```

```bash
for id in {1,2,3}; do
cfssl gencert \
  -ca=/opt/certs/ca.pem \
  -ca-key=/opt/certs/ca-key.pem \
  -config=/opt/certs/ca-config.json \
  -hostname=k8s-0${id}.internal.example.com,k8s-0${id},10.240.1.3${id} \
  -profile=kubernetes \
  /opt/certs/k8s-0${id}-csr.json | cfssljson -bare /opt/certs/k8s-0${id}
done
```

```bash
ls /opt/certs/ |grep k8s-0
  k8s-01-csr.json
  k8s-01-key.pem
  k8s-01.csr
  k8s-01.pem
  k8s-02-csr.json
  k8s-02-key.pem
  k8s-02.csr
  k8s-02.pem
  k8s-03-csr.json
  k8s-03-key.pem
  k8s-03.csr
  k8s-03.pem
```

### The kube-controller-manager certificate

```bash
cat > /opt/certs/kube-controller-manager-csr.json <<EOF
{
  "CN": "system:kube-controller-manager",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "FR",
      "L": "Example City",
      "O": "system:kube-controller-manager",
      "OU": "Kubernetes The Hard Way",
      "ST": "Example State"
    }
  ]
}
EOF

cfssl gencert \
  -ca=/opt/certs/ca.pem \
  -ca-key=/opt/certs/ca-key.pem \
  -config=/opt/certs/ca-config.json \
  -profile=kubernetes \
  /opt/certs/kube-controller-manager-csr.json | cfssljson -bare /opt/certs/kube-controller-manager
```

```bash
ls /opt/certs/ |grep kube-controller-manager
  kube-controller-manager-csr.json
  kube-controller-manager-key.pem
  kube-controller-manager.csr
  kube-controller-manager.pem
```

### The kube-proxy certificate

```bash
cat > /opt/certs/kube-proxy-csr.json <<EOF
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "FR",
      "L": "Example City",
      "O": "system:node-proxier",
      "OU": "Kubernetes The Hard Way",
      "ST": "Example State"
    }
  ]
}
EOF

cfssl gencert \
  -ca=/opt/certs/ca.pem \
  -ca-key=/opt/certs/ca-key.pem \
  -config=/opt/certs/ca-config.json \
  -profile=kubernetes \
  /opt/certs/kube-proxy-csr.json | cfssljson -bare /opt/certs/kube-proxy
```

```bash
ls /opt/certs/ |grep kube-proxy
  kube-proxy-csr.json
  kube-proxy-key.pem
  kube-proxy.csr
  kube-proxy.pem
```

### The kube-scheduler certificate

```bash
cat > /opt/certs/kube-scheduler-csr.json <<EOF
{
  "CN": "system:kube-scheduler",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "FR",
      "L": "Example City",
      "O": "system:kube-scheduler",
      "OU": "Kubernetes The Hard Way",
      "ST": "Example State"
    }
  ]
}
EOF

cfssl gencert \
  -ca=/opt/certs/ca.pem \
  -ca-key=/opt/certs/ca-key.pem \
  -config=/opt/certs/ca-config.json \
  -profile=kubernetes \
  /opt/certs/kube-scheduler-csr.json | cfssljson -bare /opt/certs/kube-scheduler
```

```bash
ls /opt/certs/ |grep kube-scheduler
  kube-scheduler-csr.json
  kube-scheduler-key.pem
  kube-scheduler.csr
  kube-scheduler.pem
```

### The kube-apiserver certificate

```bash
cat > /opt/certs/kubernetes-csr.json <<EOF
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "FR",
      "L": "Example City",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Example State"
    }
  ]
}
EOF

cfssl gencert \
  -ca=/opt/certs/ca.pem \
  -ca-key=/opt/certs/ca-key.pem \
  -config=/opt/certs/ca-config.json \
  -hostname=10.43.0.1,10.240.1.31,10.240.1.32,10.240.1.33,${KUBERNETES_PUBLIC_ADDRESS},${KUBERNETES_VIP_ADDRESS},127.0.0.1,${KUBERNETES_HOSTNAMES} \
  -profile=kubernetes \
  /opt/certs/kubernetes-csr.json | cfssljson -bare /opt/certs/kubernetes
```

> [!warning]
> The `-hostname` parameter is what populates the list of **subject alternative names**. Every name and address a client might use to reach the API server has to be in there, including the virtual address — a client connecting by a name that is absent will reject the certificate.

```bash
ls /opt/certs/ |grep kubernetes
  kubernetes-csr.json
  kubernetes-key.pem
  kubernetes.csr
  kubernetes.pem
```

### The ServiceAccount key pair

A *ServiceAccount* is used by containers running in pods to talk to *kube-apiserver*.

Every *namespace* has a default *ServiceAccount*.

A ServiceAccount's information is mounted inside the container through a volume, at `/var/run/secrets/kubernetes.io/serviceaccount`.

```bash
cat > /opt/certs/service-account-csr.json <<EOF
{
  "CN": "service-accounts",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "FR",
      "L": "Example City",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Example State"
    }
  ]
}
EOF

cfssl gencert \
  -ca=/opt/certs/ca.pem \
  -ca-key=/opt/certs/ca-key.pem \
  -config=/opt/certs/ca-config.json \
  -profile=kubernetes \
  /opt/certs/service-account-csr.json | cfssljson -bare /opt/certs/service-account
```

```bash
ls /opt/certs/ |grep service-account
  service-account-csr.json
  service-account-key.pem
  service-account.csr
  service-account.pem
```

The **service account** key is used by the **controller manager** to create pods and replica sets.
This is the cleanest approach, but we could also have:

- disabled service accounts entirely
  - start the API server with `--disable-admission-plugins=ServiceAccount`
  - the API server no longer creates service accounts automatically
  - pods are created without a service account
- left the token unmounted
  - by adding `automountServiceAccountToken: false` to the *spec* of our deployment
  - or `automountServiceAccountToken: false` on the default *ServiceAccount*
    - the *ReplicaSet controller* then stops creating pods that reference the missing token
  - or disabled it temporarily by patching the default service account: `kubectl patch sa default -p '{"automountServiceAccountToken": false}'`

### Distributing the certificates to the nodes

```bash
for instance in k8s-0{2,3}; do
scp -r \
  /opt/certs/ca.pem \
  /opt/certs/ca-key.pem \
  /opt/certs/kubernetes-key.pem \
  /opt/certs/kubernetes.pem \
  /opt/certs/service-account-key.pem \
  /opt/certs/service-account.pem \
  /opt/certs/${instance}-key.pem \
  /opt/certs/${instance}.pem \
  ${instance}:/opt/certs/
done
```

## Generating the kubeconfigs

In this part we generate the Kubernetes configuration files, known as *kubeconfigs*.
They let Kubernetes clients locate and authenticate to **kube-apiserver**.

We generate a kubeconfig for each of:

- the controller manager
- kubelet
- kube-proxy
- the scheduler
- the admin user

Create the directory that will hold the kubeconfigs:

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} mkdir /opt/kubeconfig
done
```

### The kubelet kubeconfigs

For the **kubelet** to be authorised by the **Kubernetes Node Authorizer**, the name used must match the server's name and the name recorded in its certificate.

```bash
for instance in k8s-0{1,2,3}; do
  kubectl config set-cluster lab \
    --certificate-authority=/opt/certs/ca.pem \
    --embed-certs=true \
    --server=https://k8s-api.internal.example.com:6443 \
    --kubeconfig=/opt/kubeconfig/${instance}.kubeconfig

  kubectl config set-credentials system:node:${instance} \
    --client-certificate=/opt/certs/${instance}.pem \
    --client-key=/opt/certs/${instance}-key.pem \
    --embed-certs=true \
    --kubeconfig=/opt/kubeconfig/${instance}.kubeconfig

  kubectl config set-context default \
    --cluster=lab \
    --user=system:node:${instance} \
    --kubeconfig=/opt/kubeconfig/${instance}.kubeconfig

  kubectl config use-context default --kubeconfig=/opt/kubeconfig/${instance}.kubeconfig
done
```

```bash
ls /opt/kubeconfig/ |grep kubeconfig
  k8s-01.kubeconfig
  k8s-02.kubeconfig
  k8s-03.kubeconfig
```

### The kube-proxy kubeconfig

```bash
kubectl config set-cluster lab \
  --certificate-authority=/opt/certs/ca.pem \
  --embed-certs=true \
  --server=https://k8s-api.internal.example.com:6443 \
  --kubeconfig=/opt/kubeconfig/kube-proxy.kubeconfig

kubectl config set-credentials system:kube-proxy \
  --client-certificate=/opt/certs/kube-proxy.pem \
  --client-key=/opt/certs/kube-proxy-key.pem \
  --embed-certs=true \
  --kubeconfig=/opt/kubeconfig/kube-proxy.kubeconfig

kubectl config set-context default \
  --cluster=lab \
  --user=system:kube-proxy \
  --kubeconfig=/opt/kubeconfig/kube-proxy.kubeconfig

kubectl config use-context default --kubeconfig=/opt/kubeconfig/kube-proxy.kubeconfig
```

```bash
ls /opt/kubeconfig/ |grep kube-proxy
  kube-proxy.kubeconfig
```

### The kube-controller-manager kubeconfig

```bash
kubectl config set-cluster lab \
  --certificate-authority=/opt/certs/ca.pem \
  --embed-certs=true \
  --server=https://k8s-api.internal.example.com:6443 \
  --kubeconfig=/opt/kubeconfig/kube-controller-manager.kubeconfig

kubectl config set-credentials system:kube-controller-manager \
  --client-certificate=/opt/certs/kube-controller-manager.pem \
  --client-key=/opt/certs/kube-controller-manager-key.pem \
  --embed-certs=true \
  --kubeconfig=/opt/kubeconfig/kube-controller-manager.kubeconfig

kubectl config set-context default \
  --cluster=lab \
  --user=system:kube-controller-manager \
  --kubeconfig=/opt/kubeconfig/kube-controller-manager.kubeconfig

kubectl config use-context default --kubeconfig=/opt/kubeconfig/kube-controller-manager.kubeconfig
```

```bash
ls /opt/kubeconfig/ |grep kube-controller-manager
  kube-controller-manager.kubeconfig
```

### The kube-scheduler kubeconfig

```bash
kubectl config set-cluster lab \
  --certificate-authority=/opt/certs/ca.pem \
  --embed-certs=true \
  --server=https://k8s-api.internal.example.com:6443 \
  --kubeconfig=/opt/kubeconfig/kube-scheduler.kubeconfig

kubectl config set-credentials system:kube-scheduler \
  --client-certificate=/opt/certs/kube-scheduler.pem \
  --client-key=/opt/certs/kube-scheduler-key.pem \
  --embed-certs=true \
  --kubeconfig=/opt/kubeconfig/kube-scheduler.kubeconfig

kubectl config set-context default \
  --cluster=lab \
  --user=system:kube-scheduler \
  --kubeconfig=/opt/kubeconfig/kube-scheduler.kubeconfig

kubectl config use-context default --kubeconfig=/opt/kubeconfig/kube-scheduler.kubeconfig
```

```bash
ls /opt/kubeconfig/ |grep kube-scheduler
  kube-scheduler.kubeconfig
```

### The kubeconfig for the admin user

```bash
kubectl config set-cluster lab \
  --certificate-authority=/opt/certs/ca.pem \
  --embed-certs=true \
  --server=https://k8s-api.internal.example.com:6443 \
  --kubeconfig=/opt/kubeconfig/admin.kubeconfig

kubectl config set-credentials admin \
  --client-certificate=/opt/certs/admin.pem \
  --client-key=/opt/certs/admin-key.pem \
  --embed-certs=true \
  --kubeconfig=/opt/kubeconfig/admin.kubeconfig

kubectl config set-context default \
  --cluster=lab \
  --user=admin \
  --kubeconfig=/opt/kubeconfig/admin.kubeconfig

kubectl config use-context default --kubeconfig=/opt/kubeconfig/admin.kubeconfig
```

```bash
ls /opt/kubeconfig/ |grep admin
  admin.kubeconfig
```

### Distributing the kubeconfigs to the nodes

```bash
for instance in k8s-0{2,3}; do
scp -r \
  /opt/kubeconfig/${instance}.kubeconfig \
  /opt/kubeconfig/kube-proxy.kubeconfig \
  /opt/kubeconfig/admin.kubeconfig \
  /opt/kubeconfig/kube-controller-manager.kubeconfig \
  /opt/kubeconfig/kube-scheduler.kubeconfig \
  ${instance}:/opt/kubeconfig/
done
```

## The encryption key

### Generating an encryption key

Kubernetes stores a significant amount of critical data — cluster state, application configuration and secrets. It supports encrypting that data at rest.

```bash
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
cat > /opt/encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF
```

### Distributing the encryption key

```bash
for instance in k8s-0{2,3}; do
scp /opt/encryption-config.yaml \
  ${instance}:/opt/
done
```

## etcd and a clustered control plane

### Bootstrapping etcd

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} mkdir -p /etc/etcd
ssh ${instance} mkdir -m 600 -p /var/lib/etcd
ssh ${instance} cp \
  /opt/certs/ca.pem \
  /opt/certs/kubernetes-key.pem \
  /opt/certs/kubernetes.pem \
  /etc/etcd/
ssh ${instance} chmod 600 /var/lib/etcd
done
```

Connect to each server to write the systemd unit:

```bash
cat <<EOF | tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name ${ETCD_NAME} \\
  --cert-file=/etc/etcd/kubernetes.pem \\
  --key-file=/etc/etcd/kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/kubernetes.pem \\
  --peer-key-file=/etc/etcd/kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${ETCD_PUBLIC_ADDRESS}:2380 \\
  --listen-peer-urls https://${ETCD_PUBLIC_ADDRESS}:2380 \\
  --listen-client-urls https://${ETCD_PUBLIC_ADDRESS}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${ETCD_PUBLIC_ADDRESS}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster k8s-01=https://10.240.1.31:2380,k8s-02=https://10.240.1.32:2380,k8s-03=https://10.240.1.33:2380 \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

> [!warning]
> In `--initial-cluster` you must give the IP addresses and short names of your cluster's nodes. **The values are not worked out automatically.**
>
> The following parameters can also take the address of an internal network, if you have given the machines a second interface to segregate traffic for better security:
>
> - `--initial-advertise-peer-urls https://${INTERNAL_IP}:2380`
> - `--listen-peer-urls https://${INTERNAL_IP}:2380`
> - `--listen-client-urls https://${INTERNAL_IP}:2379,https://127.0.0.1:2379`
> - `--advertise-client-urls https://${INTERNAL_IP}:2379`

We can now start the **etcd** cluster:

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} systemctl daemon-reload
ssh ${instance} systemctl enable --now etcd
done
```

And check that the cluster works:

```bash
ETCDCTL_API=3 etcdctl member list --endpoints=https://127.0.0.1:2379 --cacert=/etc/etcd/ca.pem --cert=/etc/etcd/kubernetes.pem --key=/etc/etcd/kubernetes-key.pem

  3db639eed5272c1, started, k8s-02, https://10.240.1.32:2380, https://10.240.1.32:2379, false
  ea0d8a8f9c2ce4bf, started, k8s-03, https://10.240.1.33:2380, https://10.240.1.33:2379, false
  f4ba1d997a75e5fe, started, k8s-01, https://10.240.1.31:2380, https://10.240.1.31:2379, false
```

### Bootstrapping the control plane

In this part we deploy the Kubernetes control plane on three nodes and configure it for high availability.
We rely mainly on the virtual IP address managed by keepalived. For a cluster with heavy load and/or a large number of nodes to manage, deploying an external load balancer is recommended.
We install these components:

- kube-apiserver
- kube-scheduler
- kube-controller-manager

#### The kube-apiserver service

We deploy the certificates and the **kube-apiserver** configuration generated earlier:

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} mkdir -p /etc/kubernetes/config
ssh ${instance} mkdir -p /var/lib/kubernetes
ssh ${instance} cp \
  /opt/certs/ca.pem \
  /opt/certs/ca-key.pem \
  /opt/certs/kubernetes-key.pem \
  /opt/certs/kubernetes.pem \
  /opt/certs/service-account-key.pem \
  /opt/certs/service-account.pem \
  /opt/encryption-config.yaml \
  /var/lib/kubernetes/
done
```

Connect to each server to write the systemd unit:

```bash
cat <<EOF | tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${KUBERNETES_PUBLIC_ADDRESS} \\
  --allow-privileged=true \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --enable-admission-plugins=NodeRestriction \\
  --etcd-cafile=/var/lib/kubernetes/ca.pem \\
  --etcd-certfile=/var/lib/kubernetes/kubernetes.pem \\
  --etcd-keyfile=/var/lib/kubernetes/kubernetes-key.pem \\
  --etcd-servers=https://10.240.1.31:2379,https://10.240.1.32:2379,https://10.240.1.33:2379 \\
  --event-ttl=1h0m0s \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \\
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem \\
  --runtime-config='api/all=true' \\
  --service-account-key-file=/var/lib/kubernetes/service-account.pem \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-account-issuer=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \\
  --service-cluster-ip-range=10.43.0.0/24 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

> [!warning]
> In `--etcd-servers` you must give the IP addresses of your cluster's etcd nodes. **The values are not worked out automatically.**
>
> The `--advertise-address=` parameter can also take the address of an internal network, if you have given the machines a second interface to segregate traffic for better security.
>
> For more on configuring the service, see [the official documentation](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/).

#### The kube-controller-manager service

We deploy the **kube-controller-manager** configuration generated earlier:

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} cp \
  /opt/kubeconfig/kube-controller-manager.kubeconfig \
  /var/lib/kubernetes/
done
```

Connect to each server to write the systemd unit:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --allocate-node-cidrs \\
  --bind-address=0.0.0.0 \\
  --cluster-cidr=10.42.0.0/16 \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --root-ca-file=/var/lib/kubernetes/ca.pem \\
  --service-account-private-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-cluster-ip-range=10.43.0.0/24 \\
  --use-service-account-credentials=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

> [!warning]
> About `--cluster-cidr`:
>
> - it defines the *CIDR* from which Kubernetes assigns IP addresses to the **pods** in our cluster
> - it is a private network, not routable outside the cluster
> - the default value is `10.42.0.0/16`
> - it requires `--allocate-node-cidrs` to be *true*
>
> About `--service-cluster-ip-range`:
>
> - it defines the *CIDR* from which Kubernetes assigns IP addresses to the **services** in our cluster
> - it is a private network, not routable outside the cluster
> - the default value is `10.43.0.0/16`
> - it must match the value given in the **kube-apiserver** configuration, or Services will be allocated addresses the API server does not expect
>
> For more on configuring the service, see [the official documentation](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/).

#### The kube-scheduler service

We deploy the **kube-scheduler** configuration generated earlier:

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} cp \
  /opt/kubeconfig/kube-scheduler.kubeconfig \
  /var/lib/kubernetes/
done
```

Connect to each server to write the configuration file:

```bash
cat <<EOF | sudo tee /etc/kubernetes/config/kube-scheduler.yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: "/var/lib/kubernetes/kube-scheduler.kubeconfig"
leaderElection:
  leaderElect: true
EOF
```

> [!note] `v1`, not `v1beta1`
> kube-scheduler 1.36 stops with `no kind "KubeSchedulerConfiguration" is registered
> for version "kubescheduler.config.k8s.io/v1beta1"`. Use `v1`, stable since 1.25.

Connect to each server to write the systemd unit:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --config=/etc/kubernetes/config/kube-scheduler.yaml \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

> [!warning]
> For more on configuring the service, see [the official documentation](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-scheduler/).

#### Starting the control plane

We can now start the **control plane**:

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} systemctl daemon-reload
ssh ${instance} systemctl enable --now kube-apiserver kube-controller-manager kube-scheduler
done
```

On starting, **kube-scheduler** reports a *CSI* error:

```bash
Aug 18 14:14:37 k8s-01.internal.example.com kube-scheduler[13064]: E0818 14:14:37.098447   13064 reflector.go:138] k8s.io/client-go/informers/factory.go:134: Failed to watch *v1.CSINode: failed to list *v1.CSINode: csinodes.storage.k8s.io is forbidden: User "system:kube-scheduler" cannot list resource "csinodes" in API group "storage.k8s.io" at the cluster scope
Aug 18 14:14:37 k8s-01.internal.example.com kube-scheduler[13064]: E0818 14:14:37.127690   13064 reflector.go:138] k8s.io/client-go/informers/factory.go:134: Failed to watch *v1.PersistentVolumeClaim: failed to list *v1.PersistentVolumeClaim: persistentvolumeclaims is forbidden: User "system:kube-scheduler" cannot list resource "persistentvolumeclaims" in API group "" at the cluster scope
Aug 18 14:14:37 k8s-01.internal.example.com kube-scheduler[13064]: E0818 14:14:37.204604   13064 reflector.go:138] k8s.io/client-go/informers/factory.go:134: Failed to watch *v1.ReplicationController: failed to list *v1.ReplicationController: replicationcontrollers is forbidden: User "system:kube-scheduler" cannot list resource "replicationcontrollers" in API group "" at the cluster scope
```

These errors are expected. The scheduler starts before the API server has created the
default RBAC roles, and it retries. They stop by themselves after a few seconds.

#### Checking the control plane

```bash
kubectl cluster-info --kubeconfig /opt/kubeconfig/admin.kubeconfig

  Kubernetes control plane is running at https://k8s-api.internal.example.com:6443
  To further debug and diagnose cluster problems, use 'kubectl cluster-info dump'.

curl --cacert /opt/certs/ca.pem https://k8s-api.internal.example.com:6443/healthz
  
  ok

curl --cacert /opt/certs/ca.pem https://k8s-api.internal.example.com:6443/version
  {
    "major": "1",
    "minor": "21",
    "gitVersion": "v1.21.0",
    "gitCommit": "cb303e613a121a29364f75cc67d3d580833a7479",
    "gitTreeState": "clean",
    "buildDate": "2021-04-08T16:25:06Z",
    "goVersion": "go1.16.1",
    "compiler": "gc",
    "platform": "linux/amd64"
  }
```

### Kubelet RBAC

Now we configure the RBAC permissions that let the **Kubernetes API server** reach the **kubelet API** on each **worker** node. In our case the control plane nodes are also workers; in production it is advisable to separate them.
Access to the **kubelet API** is required to fetch metrics and logs, and to run commands in pods.
In this lab we set the kubelet's `--authorization-mode` to *Webhook*. That mode uses the *SubjectAccessReview* API to decide authorisation.

Create the **ClusterRole** *system:kube-apiserver-to-kubelet* with permission to use the kubelet API and perform the associated tasks:

```bash
cat <<EOF | kubectl apply --kubeconfig /opt/kubeconfig/admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - ""
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
    verbs:
      - "*"
EOF
```

The **Kubernetes API server** authenticates to the **kubelet** as the user *kubernetes*, as defined on **kube-apiserver** by the `--kubelet-client-certificate` parameter.

Bind the **ClusterRole** *system:kube-apiserver-to-kubelet* to the *kubernetes* user:

```bash
cat <<EOF | kubectl apply --kubeconfig /opt/kubeconfig/admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: ""
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kubernetes
EOF
```

### Bootstrapping the worker nodes

#### Prerequisites

We install these packages:

- **iptables** — kube-proxy writes its rules with it, and Leap 16 does not install it by default
- **socat** — needed for `kubectl port-forward`
- **ipset** — administers *Netfilter* sets
- **conntrack-tools** — tracks connections with *Netfilter*

```bash
zypper install -y iptables socat conntrackd ipset
```

By default **kubelet** refuses to start if swap is enabled:

```bash
swapon --show
swapoff -a
swapon --show
```

We create the directories it needs:

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} mkdir -p \
  /etc/cni/net.d \
  /etc/containerd \
  /opt/cni/bin \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes \
  /var/run/kubernetes
done
```

Pods on a bridge reach Services through iptables only when the kernel sends bridged
traffic through it, and the node must forward packets:

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} 'modprobe br_netfilter && echo br_netfilter >/etc/modules-load.d/k8s.conf'
ssh ${instance} 'printf "net.bridge.bridge-nf-call-iptables = 1\nnet.ipv4.ip_forward = 1\n" >/etc/sysctl.d/99-k8s.conf && sysctl -q --system'
done
```

> [!warning] `br_netfilter` and these sysctls are needed
> Without them, a pod cannot reach a Service whose only backend runs on the same node:
> the reply skips iptables and DNS lookups time out. kubeadm checks both before it
> installs a node.

#### CNI

We create two simple **cni-plugins** configurations.

The first is a plain virtual interface of type **linux bridge**.
Every pod using this plugin attaches to that **bridge** and is given an IP address from the supplied CIDR.
In this example *IPAM* is local, so the CIDR has to be unique per node.
Other plugins, which we look at later, provide more capable behaviour.

Deploying a real **CNI** is outside the scope of this lab. Here we simply have pods that talk directly to the outside network. See [[kubernetes/my-notes/cni]] for the plugin contract, and virtual-interfaces for what a Linux bridge actually is.

```bash
POD_CIDR=10.42.1.0/24   # k8s-01; 10.42.2.0/24 on k8s-02, 10.42.3.0/24 on k8s-03
cat <<EOF | sudo tee /etc/cni/net.d/10-bridge.conf
{
    "cniVersion": "0.4.0",
    "name": "bridge",
    "type": "bridge",
    "bridge": "cnio0",
    "isGateway": true,
    "ipMasq": true,
    "ipam": {
        "type": "host-local",
        "ranges": [
          [{"subnet": "${POD_CIDR}"}]
        ],
        "routes": [{"dst": "0.0.0.0/0"}]
    }
}
EOF
```

> [!note] One pod range per node
> Each node's `host-local` IPAM needs its own range, outside the node network
> (10.240.1.0/24). Each node gets one /24 from the cluster CIDR, `10.42.0.0/16`.

Each node must also know where the other nodes' pods are. Without a real CNI, that is
one static route per other node:

```bash
for id in 1 2 3; do
  for peer in 1 2 3; do
    [ $id = $peer ] || ssh k8s-0${id} ip route add 10.42.${peer}.0/24 via 10.240.1.3${peer}
  done
done
```

The second is a **loopback** interface, for internal communication:

```bash
cat <<EOF | sudo tee /etc/cni/net.d/99-loopback.conf
{
    "cniVersion": "0.4.0",
    "name": "lo",
    "type": "loopback"
}
EOF
```

#### containerd

We create a **containerd** configuration file specifying **runc** as the runtime behind the **CRI**:

```bash
cat << EOF | sudo tee /etc/containerd/config.toml
version = 3
root = "/var/lib/containerd"
state = "/run/containerd"

[grpc]
  max_recv_message_size = 16777216
  max_send_message_size = 16777216

[debug]
  level = "info"

[plugins]
  [plugins."io.containerd.cri.v1.images"]
    snapshotter = "overlayfs"
    [plugins."io.containerd.cri.v1.images".pinned_images]
      sandbox = "registry.k8s.io/pause:3.10"
  [plugins."io.containerd.cri.v1.runtime"]
    max_container_log_line_size = -1
    [plugins."io.containerd.cri.v1.runtime".containerd]
      default_runtime_name = "runc"
      [plugins."io.containerd.cri.v1.runtime".containerd.runtimes]
        [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]
            SystemdCgroup = true
EOF
```

> [!warning] containerd 2.x uses a new config format
> containerd 2.x rejects a config file written for 1.6. Three things differ:
>
> - **`version = 2` → `version = 3`.**
> - **The CRI plugin was split.** `io.containerd.grpc.v1.cri` became
>   `io.containerd.cri.v1.runtime` (runtimes, logging) and
>   `io.containerd.cri.v1.images` (snapshotter, sandbox image). `sandbox_image`
>   moved to `pinned_images.sandbox`.
> - **`systemdCgroup` → `SystemdCgroup`.** TOML keys are case-sensitive and the
>   option is capitalised, so a lowercase key is silently ignored — meaning
>   the cgroup driver does not actually match the `cgroupDriver: systemd` set for
>   kubelet below. A mismatch there causes pods to fail under memory pressure in
>   ways that are hard to attribute.
>
> If you have an old config, `containerd config migrate` converts it rather than
> making you do this by hand. Confirm the pause image matches what your kubelet
> expects — a mismatch leaves orphaned sandboxes.

Then a **systemd** unit:

```bash
cat <<EOF | sudo tee /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd

Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
```

Behind a proxy, adapt the configuration like this:

```bash
mkdir /etc/systemd/system/containerd.service.d/
cat <<EOF | sudo tee /etc/systemd/system/containerd.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=http://10.240.254.25:8080" "HTTPS_PROXY=http://10.240.254.25:8080" "NO_PROXY=10.240.1./24,k8s-01,k8s-02,k8s-03,k8s-01.cluster.local,.internal.example.com,127.0.0.1,localhost,10.233.0.0/18,10.233.64.0/18,svc,svc.cluster.local"
EOF
```

#### kubelet

We deploy the certificates generated earlier:

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} cp \
  /opt/certs/${instance}-key.pem \
  /opt/certs/${instance}.pem \
  /opt/certs/ca.pem \
  /var/lib/kubelet
done
```

Then the **kubeconfig**:

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} cp \
  /opt/kubeconfig/${instance}.kubeconfig \
  /var/lib/kubelet/kubeconfig
done
```

The **kubelet** configuration file:

```bash
POD_CIDR=10.42.1.0/24   # k8s-01; 10.42.2.0/24 on k8s-02, 10.42.3.0/24 on k8s-03
cat <<EOF | sudo tee /var/lib/kubelet/kubelet-config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.pem"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
cgroupDriver: systemd
clusterDNS:
  - "10.43.0.10"
podCIDR: "${POD_CIDR}"
resolvConf: "/etc/resolv.conf"
runtimeRequestTimeout: "15m"
containerRuntimeEndpoint: "unix:///run/containerd/containerd.sock"
tlsCertFile: "/var/lib/kubelet/${KUBELET_NAME}.pem"
tlsPrivateKeyFile: "/var/lib/kubelet/${KUBELET_NAME}-key.pem"
EOF
```

And finally a **systemd** unit:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --register-node=true \\
  --node-ip=${KUBERNETES_PUBLIC_ADDRESS} \\
  --hostname-override=${KUBELET_NAME} \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

> [!warning] Four kubelet flags were removed, not deprecated
> Older guides pass kubelet flags that no longer exist. kubelet **refuses to start**
> on an unknown flag:
>
> | Flag | Gone since | Replacement |
> | --- | --- | --- |
> | `--network-plugin=cni` | 1.24 | Nothing — CNI is the only option now |
> | `--container-runtime=remote` | 1.27 | Nothing — `remote` is the only option now |
> | `--container-runtime-endpoint` | 1.27 | `containerRuntimeEndpoint` in `kubelet-config.yaml`, added above |
> | `--image-pull-progress-deadline` | 1.27 | `imagePullProgressDeadline` in the config file, if you need it |
>
> This is the general direction of travel: kubelet flags keep migrating into the
> `KubeletConfiguration` file, which unlike flags can be changed without editing a
> systemd unit. Prefer the config file for anything new.

#### kube-proxy

We will not use this component in production with the *Cilium* **CNI**, since Cilium replaces it effectively.

As a reminder, **kube-proxy** is — as the name says — a proxy running on every node. It maintains the network rules that allow pods to communicate inside and outside the cluster.

It uses the operating system's packet filtering (Netfilter/iptables in our case — see [[networking/iptables]]).

Create the configuration file:

```bash
cat <<EOF | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "10.42.0.0/16"
EOF
```

Then the **kubeconfig**:

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} cp \
  /opt/kubeconfig/kube-proxy.kubeconfig \
  /var/lib/kube-proxy/kubeconfig
done
```

And finally a **systemd** unit:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

#### Starting the worker services

```bash
for instance in k8s-0{1,2,3}; do
ssh ${instance} systemctl daemon-reload 
ssh ${instance} systemctl enable --now containerd kubelet kube-proxy
done
```

#### Checking

```bash
kubectl get nodes --kubeconfig /opt/kubeconfig/admin.kubeconfig
  NAME         STATUS   ROLES    AGE   VERSION
  k8s-01   Ready    <none>   73s   v1.36.2
  k8s-02   Ready    <none>   25s   v1.36.2
  k8s-03   Ready    <none>   29s   v1.36.2
```

#### DNS

Now that the cluster works, the one thing still missing before we can run services is DNS.
We deploy a DNS plugin provided by **CoreDNS**. It offers a DNS service based on automatic discovery of the applications running in a Kubernetes cluster.

```bash
cat <<EOF | kubectl apply --kubeconfig /opt/kubeconfig/admin.kubeconfig -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: coredns
  namespace: kube-system
  labels:
    addonmanager.kubernetes.io/mode: Reconcile
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
    addonmanager.kubernetes.io/mode: Reconcile
  name: system:coredns
rules:
  - apiGroups:
      - ""
    resources:
      - endpoints
      - services
      - pods
      - namespaces
    verbs:
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - nodes
    verbs:
      - get
  - apiGroups:
      - discovery.k8s.io
    resources:
      - endpointslices
    verbs:
      - list
      - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:coredns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:coredns
subjects:
- kind: ServiceAccount
  name: coredns
  namespace: kube-system
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
          lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . 10.240.101.101 {
          max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/name: "CoreDNS"
spec:
  # replicas: not specified here:
  # 1. Default is 1.
  # 2. Will be tuned in real time if DNS horizontal auto-scaling is turned on.
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  selector:
    matchLabels:
      k8s-app: kube-dns
  template:
    metadata:
      labels:
        k8s-app: kube-dns
    spec:
      priorityClassName: system-cluster-critical
      serviceAccountName: coredns
      tolerations:
        - key: "CriticalAddonsOnly"
          operator: "Exists"
      nodeSelector:
        kubernetes.io/os: linux
      affinity:
         podAntiAffinity:
           requiredDuringSchedulingIgnoredDuringExecution:
           - labelSelector:
               matchExpressions:
               - key: k8s-app
                 operator: In
                 values: ["kube-dns"]
             topologyKey: kubernetes.io/hostname
      containers:
      - name: coredns
        image: coredns/coredns:1.14.6
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
        args: [ "-conf", "/etc/coredns/Corefile" ]
        volumeMounts:
        - name: config-volume
          mountPath: /etc/coredns
          readOnly: true
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        - containerPort: 9153
          name: metrics
          protocol: TCP
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            add:
            - NET_BIND_SERVICE
            drop:
            - all
          readOnlyRootFilesystem: true
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /ready
            port: 8181
            scheme: HTTP
      dnsPolicy: Default
      volumes:
        - name: config-volume
          configMap:
            name: coredns
            items:
            - key: Corefile
              path: Corefile
---
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  annotations:
    prometheus.io/port: "9153"
    prometheus.io/scrape: "true"
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "CoreDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: 10.43.0.10
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
  - name: metrics
    port: 9153
    protocol: TCP
EOF
```

> [!warning]
> In the kubelet configuration we specified this:
>
>   clusterDNS:
>     - "10.43.0.10"
>
> which echoes this part of the CoreDNS deployment YAML:
>
>   spec:
>     selector:
>       k8s-app: kube-dns
>     clusterIP: 10.43.0.10
>
> If you want a forwarder, change this part:
>
>   forward . 10.240.101.101

## Remote access

To reach the cluster remotely we generate a *kubeconfig* for our admin user.

```bash
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=/opt/certs/ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_VIP_ADDRESS}:6443

  kubectl config set-credentials admin \
    --client-certificate=/opt/certs/admin.pem \
    --client-key=/opt/certs/admin-key.pem

  kubectl config set-context kubernetes-the-hard-way \
    --cluster=kubernetes-the-hard-way \
    --user=admin

  kubectl config use-context kubernetes-the-hard-way
```

To check the configuration:

```bash
kubectl config view

  apiVersion: v1
  clusters:
  - cluster:
      certificate-authority-data: DATA+OMITTED
      server: https://10.240.1.30:6443
    name: kubernetes-the-hard-way
  contexts:
  - context:
      cluster: kubernetes-the-hard-way
      user: admin
    name: kubernetes-the-hard-way
  current-context: kubernetes-the-hard-way
  kind: Config
  preferences: {}
  users:
  - name: admin
    user:
      client-certificate: /opt/certs/admin.pem
      client-key: /opt/certs/admin-key.pem

kubectl get nodes
  NAME         STATUS   ROLES    AGE     VERSION
  k8s-01   Ready    <none>   7m42s   v1.36.2
  k8s-02   Ready    <none>   6m54s   v1.36.2
  k8s-03   Ready    <none>   6m58s   v1.36.2

kubectl version
  Client Version: version.Info{Major:"1", Minor:"21", GitVersion:"v1.21.0", GitCommit:"cb303e613a121a29364f75cc67d3d580833a7479", GitTreeState:"clean", BuildDate:"2021-04-08T16:31:21Z", GoVersion:"go1.16.1", Compiler:"gc", Platform:"linux/amd64"}
  Server Version: version.Info{Major:"1", Minor:"21", GitVersion:"v1.21.0", GitCommit:"cb303e613a121a29364f75cc67d3d580833a7479", GitTreeState:"clean", BuildDate:"2021-04-08T16:25:06Z", GoVersion:"go1.16.1", Compiler:"gc", Platform:"linux/amd64"}
```

We no longer need to pass the kubeconfig file with `--kubeconfig /opt/kubeconfig/admin.kubeconfig`.

## Using the API server

List the nodes:

```bash
kubectl get nodes
  NAME         STATUS   ROLES    AGE     VERSION
  k8s-01   Ready    <none>   7m42s   v1.36.2
  k8s-02   Ready    <none>   6m54s   v1.36.2
  k8s-03   Ready    <none>   6m58s   v1.36.2
```

List the pods in every *namespace*:

```bash
kubectl get pods -A
  NAMESPACE     NAME                       READY   STATUS    RESTARTS   AGE
  kube-system   coredns-7b4964fc5d-4fht8   1/1     Running   0          5m
```

List the services:

```bash
kubectl get services
  NAME         TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
  kubernetes   ClusterIP   10.43.0.1    <none>        443/TCP   52m
```

Only CoreDNS runs so far.

**kube-apiserver** creates the `kubernetes` service automatically.

## Creating a Deployment

We start by creating a deployment holding an Nginx web server.

```bash
kubectl create deployment web --image=nginx
```

We can see it:

```bash
kubectl get deployment
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
  coredns   1/1     1            1           69m
  web       1/1     1            1           21m

kubectl get pods -l k8s-app=kube-dns -n kube-system
  NAME                       READY   STATUS    RESTARTS   AGE
  coredns-6cc5596b8c-gp9fn   1/1     Running   0          29m
```

Turning the verbosity up a little shows the IP addresses assigned by the CNI plugin, and the range they came from:

```bash
kubectl get pods -o wide
  NAME                  READY   STATUS    RESTARTS   AGE   IP          NODE     NOMINATED NODE   READINESS GATES
  web-96d5df5c8-4p9qz   1/1     Running   0          2m    10.42.2.3   k8s-02   <none>           <none>
```

The address comes from the node's range: `10.42.2.0/24` on k8s-02.

And we can reach those pods from any node, thanks to the static routes — the web one,
for instance:

```bash
curl http://10.42.2.3
```

We should see the `Welcome to nginx!` page.

Deploying a real CNI, a proxy and a load balancer comes later.

<!-- uplink -->
Part of [[kubernetes/my-notes/index|My own Kubernetes notes]].
