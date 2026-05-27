# Stage 02-image

Imports the RHCOS Azure VHD into a managed image and publishes it as a Shared Image Gallery image version. The CPU architecture is driven by `ARCHITECTURE` in `config/cluster.env` (default `x86_64`, also supports `arm64`); the gallery image is created with the matching `architecture` attribute (`x64` or `Arm64`). See [cpu-architecture.md](../../docs/cpu-architecture.md).

Normal flow:

```bash
make image
```

`make image` first runs `scripts/upload-rhcos.sh`, which resolves the VHD URL from the local `openshift-install` release stream and uploads it through the in-VNet uploader VM.
