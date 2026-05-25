# Stage 02-image

Imports the RHCOS ARM64 Azure VHD into a managed image and publishes it as a Shared Image Gallery image version.

Normal flow:

```bash
make image
```

`make image` first runs `scripts/upload-rhcos.sh`, which resolves the VHD URL from the local `openshift-install` release stream and uploads it through the in-VNet uploader VM.
