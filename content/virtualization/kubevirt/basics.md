---
title: KubeVirt basics
description: Installing the operator and CDI, virtctl, defining a first VM from a container disk or a DataVolume, and cloud-init
tags: [virtualization, kubevirt, kubernetes, installation]
type: howto
status: complete
---

# KubeVirt basics

> [!note] Partly tested
> No test cluster runs KubeVirt: the test Mac has no KVM, and KubeVirt on arm64
> cannot use software emulation. The tests check the release URLs, validate every
> manifest against KubeVirt's API schema, and run `virtctl` and the `jq` commands
> offline. How a running cluster behaves is not tested.

## Installing

The operator, then a `KubeVirt` custom resource that tells it to deploy:

```bash
VERSION=$(curl -s https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)

kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/kubevirt-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/kubevirt-cr.yaml"

kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=300s
```

Both lines find the latest release without the GitHub API, which allows only 60
requests an hour without a token. `stable.txt` is where the KubeVirt project publishes
its latest stable version. For CDI, `releases/latest` redirects to the latest tag.

Check what landed:

```bash
kubectl get pods -n kubevirt
kubectl get kubevirt -n kubevirt -o yaml
```

### CDI

The **Containerized Data Importer** populates VM disks from qcow2 images, URLs,
registries or uploads. You want it:

```bash
CDI=$(basename "$(curl -s -o /dev/null -w '%{redirect_url}' https://github.com/kubevirt/containerized-data-importer/releases/latest)")

kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI}/cdi-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI}/cdi-cr.yaml"
```

### virtctl

The CLI for the things `kubectl` cannot express — console access, power control, image
upload:

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
curl -L -o virtctl \
  "https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/virtctl-${VERSION}-linux-${ARCH}"
chmod +x virtctl && sudo mv virtctl /usr/local/bin/

# or as a kubectl plugin, via krew
kubectl krew install virt
```

## A first VM

The quickest start uses a **container disk** — a VM image packaged in a container
image, pulled like any other:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fedora-01
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/domain: fedora-01
    spec:
      domain:
        cpu:
          cores: 2
        memory:
          guest: 2Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              user: fedora
              password: fedora
              chpasswd: { expire: False }
              ssh_authorized_keys:
                - ssh-ed25519 AAAA... your.name@example.com
```

```bash
kubectl apply -f fedora-01.yaml
kubectl get vm,vmi
virtctl console fedora-01
```

> [!warning] A container disk is ephemeral
> The image is pulled read-only and writes go to a scratch overlay that is **discarded
> when the VMI stops**. It is excellent for stateless VMs, testing and CI, and wrong
> for anything whose state matters.
>
> For persistence, use a `DataVolume` backed by a PVC — below.

## Persistent disks with DataVolumes

CDI populates a PVC from a source, and the VM uses that:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: rocky-01
spec:
  runStrategy: Always
  dataVolumeTemplates:
    - metadata:
        name: rocky-01-root
      spec:
        storage:
          resources:
            requests:
              storage: 20Gi
          storageClassName: fast-rwx
        source:
          http:
            url: "https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"
  template:
    spec:
      domain:
        cpu:
          cores: 2
        memory:
          guest: 4Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: rocky-01-root
```

Sources include `http`, `registry`, `pvc` (clone), `snapshot`, `s3`, `gcs`,
`upload` and `blank`, plus `imageio` (oVirt) and `vddk` (VMware) for migrations.

```bash
kubectl get dv                 # watch the import
kubectl get pvc
```

> [!important] `ReadWriteMany` for live migration, `volumeMode: Block` for speed
> Live migration needs shared storage the destination node can attach while the
> source still holds it — so `ReadWriteMany`. `volumeMode: Block` is not required, but
> it avoids a filesystem layer between QEMU and the disk. That is faster, and it is
> what most storage vendors' CSI drivers support best for VMs.
>
> Choosing a `ReadWriteOnce` filesystem StorageClass is the most common way to build a
> KubeVirt cluster that cannot migrate anything, and it is awkward to change later.

Uploading a local image:

```bash
virtctl image-upload dv rocky-01-root \
  --size=20Gi --image-path=./Rocky-9-GenericCloud.qcow2 \
  --storage-class=fast-rwx --insecure
```

## Power and console

```bash
virtctl start rocky-01
virtctl stop rocky-01
virtctl restart rocky-01
virtctl pause vm rocky-01
virtctl unpause vm rocky-01

virtctl console rocky-01        # serial; Ctrl+] to detach
virtctl vnc rocky-01            # graphical
virtctl ssh fedora@vm/fedora-01
```

> [!warning] Correction
> An earlier version had `virtctl pause rocky-01` and `virtctl ssh fedora@fedora-01`.
> `pause` and `unpause` need the type first (`vm` or `vmi`), and `ssh` needs
> `type/name`. The short forms fail with `accepts 2 arg(s)` and
> `target must contain type and name separated by '/'`.

Or declaratively, which is what GitOps needs:

```yaml
spec:
  runStrategy: Always     # Always | RerunOnFailure | Manual | Halted | Once
```

`runStrategy` and the older `running: true` are mutually exclusive — set one.
`running` is deprecated, so use `runStrategy`.

## Reaching a VM over the network

With `masquerade`, the VM sits behind the pod IP, so ordinary Services work:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: fedora-01-ssh
spec:
  selector:
    kubevirt.io/domain: fedora-01
  ports:
    - port: 22
      targetPort: 22
```

That is the payoff of the VM-in-a-pod model — Services, NetworkPolicies and Ingress
all apply unchanged. See [[kubernetes/networking/service-types]].

## Instance types

Rather than repeating CPU and memory in every VM, reference a shared shape:

```bash
kubectl get virtualmachineclusterinstancetypes
kubectl get virtualmachineclusterpreferences
```

```yaml
spec:
  instancetype:
    kind: VirtualMachineClusterInstancetype
    name: u1.medium
  preference:
    kind: VirtualMachineClusterPreference
    name: fedora
```

The preference carries guest-OS-specific defaults — bus types, firmware, clock — which
is exactly the `--os-variant` role from [[virtualization/kvm/basics]].

## Where to go next

- [[virtualization/kubevirt/advanced]] — storage, networking, live migration
- [[virtualization/kubevirt/gitops]] — managing VMs from Git
- [[virtualization/kubevirt/troubleshooting]] — when a VMI stays pending

<!-- uplink -->
Part of [[virtualization/kubevirt/index|KubeVirt]].
