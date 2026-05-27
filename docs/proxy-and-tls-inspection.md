# Proxy and TLS inspection

Enterprise networks often route outbound traffic through a
forward proxy and/or terminate TLS at a firewall (Palo Alto,
Fortinet, Check Point, Cisco, Azure Firewall Premium with TLS
inspection enabled). Both situations require additional fields
in `install-config.yaml`. This document explains when to use
each one, how to fill them in, and how to verify the result.

> **Quick test.** If `make bootstrap` proceeds past the RHCOS
> boot phase but bootstrap-control-plane never becomes ready and
> the journal on the bootstrap node shows
> `x509: certificate signed by unknown authority` against
> `quay.io` or `registry.redhat.io`, you have a TLS-inspection
> problem and the bottom half of this document applies. If the
> errors are `connection refused` or `i/o timeout`, you have a
> missing outbound allow first — fix
> [`required-outbound-destinations.md`](./required-outbound-destinations.md)
> before continuing here.

---

## 1. When to set `proxy:` in install-config

Set the `proxy:` block when **any** of the following is true:

- All outbound HTTPS in your environment is required to traverse
  a forward proxy (e.g. `proxy.corp.example.com:3128`)
- The firewall blocks direct egress from spoke VNet to the
  internet but allows it from a designated proxy subnet
- You want to centrally log container-image pulls

Skip the `proxy:` block if outbound HTTPS from the spoke VNet
goes directly to a firewall NVA without an HTTP proxy in
between. UDR + firewall is **not** an HTTP proxy and does not
need this field.

---

## 2. `proxy:` field reference

```yaml
proxy:
  httpProxy: http://proxy.corp.example.com:3128
  httpsProxy: http://proxy.corp.example.com:3128
  noProxy: .svc,.cluster.local,localhost,127.0.0.1,168.63.129.16,169.254.169.254,10.0.0.0/8,${MACHINE_NETWORK_CIDR},${SERVICE_NETWORK_CIDR},${CLUSTER_NETWORK_CIDR},${BASE_DOMAIN}
```

| Field | Meaning |
|---|---|
| `httpProxy` | Used for plain HTTP egress (rare in a fresh install) |
| `httpsProxy` | Used for HTTPS — this is what `quay.io` etc. go through |
| `noProxy` | Comma-separated list of hosts and CIDRs that must **not** use the proxy. Cluster-internal traffic, IMDS, WireServer, and your machine/cluster/service networks belong here |

### Building `noProxy` correctly

A wrong `noProxy` is the most common cause of a stuck install.
Include all of these:

| Entry | Why |
|---|---|
| `.svc`, `.cluster.local` | In-cluster service DNS |
| `localhost`, `127.0.0.1` | Loopback |
| `168.63.129.16` | Azure WireServer — must never go via proxy |
| `169.254.169.254` | Azure Instance Metadata Service — must never go via proxy |
| `<MACHINE_NETWORK_CIDR>` | Node-to-node traffic (e.g. `10.0.0.0/22`) |
| `<SERVICE_NETWORK_CIDR>` | Default `172.30.0.0/16` |
| `<CLUSTER_NETWORK_CIDR>` | Default `10.128.0.0/14` |
| `.<BASE_DOMAIN>` | Cluster API and `*.apps` — internal LB traffic |
| Any on-prem CIDR you peer to | If on-prem hosts need to reach the cluster directly |
| `.local` zones used by Azure services | E.g. `.azurecr.io` if ACR is in scope |

Leading dot (`.svc` not `svc`) makes the entry a domain suffix
match. Without the dot, only the literal hostname matches.

### `noProxy` mistakes that cause hard-to-spot failures

- Forgetting `168.63.129.16` — Azure agent extension reports stop;
  cluster reports `DegradedExtensionInstallation`
- Forgetting `169.254.169.254` — cloud-controller-manager cannot
  obtain instance metadata; LoadBalancers never attach to nodes
- Forgetting `.svc,.cluster.local` — in-cluster service calls go
  out to the proxy and time out; operators look "degraded for no
  reason"
- Forgetting the machine network CIDR — node-to-node etcd / kubelet
  traffic gets proxied; etcd quorum becomes unstable

---

## 3. `additionalTrustBundle:` for TLS-inspecting firewalls

When a firewall terminates HTTPS and re-encrypts with an internal
CA, every cluster node must trust that CA. Add the CA's PEM-encoded
certificate (chain) under `additionalTrustBundle:` in
`install-config.yaml`:

```yaml
additionalTrustBundle: |
  -----BEGIN CERTIFICATE-----
  MIIDjzCCAnegAwIBAgIQ... (root CA)
  -----END CERTIFICATE-----
  -----BEGIN CERTIFICATE-----
  MIIDkzCCAnugAwIBAgIQ... (issuing CA, if a chain)
  -----END CERTIFICATE-----
```

OpenShift installs this PEM into the system trust store on RHCOS
during ignition, and uses it for:

- The bootstrap ignition Go HTTP client (so `quay.io` pulls succeed)
- The CRI-O image pull path (so operator subscription pulls succeed)
- Day-2 user workloads (via `cluster-wide-proxy` injection)

### Getting the CA from your security team

Ask for:

> The PEM-encoded certificate chain (root and any intermediate CAs)
> that your firewall presents when it re-signs HTTPS sessions
> egressing from our cluster spoke VNet (CIDR `<your spoke CIDR>`)
> to `quay.io` and `registry.redhat.io`.

The output should be one or more `-----BEGIN CERTIFICATE-----`
blocks. Concatenate them in chain order (root last) under
`additionalTrustBundle:`.

### Verifying the CA before install

From the installer host:

```bash
openssl s_client -showcerts -connect quay.io:443 </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject
```

If the issuer line names your corporate CA (and not Let's Encrypt
or DigiCert), your firewall is terminating TLS — you need
`additionalTrustBundle`.

---

## 4. Combined example

For a cluster behind both a forward proxy **and** TLS-inspection:

```yaml
proxy:
  httpProxy: http://proxy.corp.example.com:3128
  httpsProxy: http://proxy.corp.example.com:3128
  noProxy: .svc,.cluster.local,localhost,127.0.0.1,168.63.129.16,169.254.169.254,10.0.0.0/22,172.30.0.0/16,10.128.0.0/14,.example.internal

additionalTrustBundle: |
  -----BEGIN CERTIFICATE-----
  MIIDjzCCAnegAwIBAgIQ...
  -----END CERTIFICATE-----
```

---

## 5. Day-2 CA rotation

When your security team rotates the inspection CA, update the
cluster's trust bundle without reinstalling:

```bash
oc create configmap custom-ca \
  --from-file=ca-bundle.crt=/path/to/new/ca-chain.pem \
  -n openshift-config \
  --dry-run=client -o yaml | oc apply -f -

oc patch proxy/cluster --type=merge \
  -p '{"spec":{"trustedCA":{"name":"custom-ca"}}}'
```

The cluster-network-operator distributes the new bundle to all
nodes within a few minutes. Old TLS sessions persist until they
close — restart pinned workloads if you need immediate effect.

---

## 6. Troubleshooting matrix

| Symptom | Likely cause | Fix |
|---|---|---|
| `x509: certificate signed by unknown authority` against Quay / Red Hat registries | TLS-inspection without `additionalTrustBundle` | Add the firewall CA to `additionalTrustBundle` |
| `proxyconnect tcp: dial tcp ... connect: connection refused` | `httpsProxy` set but proxy unreachable from spoke | Verify proxy URL + connectivity from a worker node |
| Cluster operators report `Degraded` with `i/o timeout` to `*.svc` | `noProxy` missing `.svc,.cluster.local` | Add them and reapply |
| `failed to get azure instance metadata` | `noProxy` missing `169.254.169.254` | Add IMDS to `noProxy` |
| LoadBalancers stuck `<pending>` | cloud-controller-manager cannot reach IMDS or `management.azure.com` via proxy | Add both to `noProxy` (IMDS) and trust bundle (ARM if inspected) |
| etcd `request timed out` after a few hours | Machine network CIDR not in `noProxy` — node-to-node proxied | Add `<MACHINE_NETWORK_CIDR>` to `noProxy` |
| Operator subscription pulls fail but bootstrap succeeded | Subscription resolves via CRI-O which uses cluster-wide-proxy, not the installer client | Verify `oc get proxy/cluster -o yaml` reflects the same `noProxy` you used at install |

---

## 7. References

- OpenShift docs: [Configuring a cluster-wide proxy](https://docs.openshift.com/container-platform/latest/networking/enable-cluster-wide-proxy.html)
- OpenShift docs: [Configuring a custom PKI](https://docs.openshift.com/container-platform/latest/networking/configuring-a-custom-pki.html)
- Companion doc: [`required-outbound-destinations.md`](./required-outbound-destinations.md)
