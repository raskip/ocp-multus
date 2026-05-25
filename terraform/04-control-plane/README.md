# Stage 04-control-plane

Creates the OpenShift control-plane VMs and attaches their NICs to the internal API/MCS load balancer backend pool.

Run this after `make bootstrap` has created the bootstrap VM and the RHCOS image stage has completed.
