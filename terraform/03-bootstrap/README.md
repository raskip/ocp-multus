# Stage 03-bootstrap

Creates the transient OpenShift bootstrap VM.

The bootstrap ignition is uploaded to private blob storage by `scripts/upload-ignition.sh`. Terraform passes only a small pointer ignition in Azure VM custom data so the payload stays below Azure custom data limits.
