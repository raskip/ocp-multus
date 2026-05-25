# Stage 05-workers

Creates worker VMs with a primary cluster NIC and a secondary Multus NIC. It also creates one optional host-device validation worker with a dedicated accelerated NIC.

After the workers boot, approve CSRs until the nodes become `Ready`, then apply the optional manifests under `manifests/`.
