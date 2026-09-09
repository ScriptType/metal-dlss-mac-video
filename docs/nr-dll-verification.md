# NR DLL verification — 2026-09-09

Keep `models/sources/nvngx_dlssnr.dll`. It is the NVIDIA-signed original, and its embedded model weights match MLX-DLSS's reference exactly. The earlier warning that the weights might differ is resolved. The reference hash is real, but identifies a modified DLL with a failing signature.

## Independently checked files

Both files contain FileVersion `310,8,0,0` and are 165,840,496 bytes long.

| File | SHA-256 | Local Authenticode result |
|---|---|---|
| Downloaded original, retained for extraction | `e16bcf15e16e13f527491cdf7845b2fe6521a738d8f7c9c721866a8496e1fc8e` | Pass, NVIDIA Corporation signer; certificate chain, timestamp and revocation checks pass |
| Exact MLX-DLSS reference, downloaded for comparison | `ceb6432f6fbdf44d886014bcd47241932bf8b67439feef9bbdd0961436662650` | Fail, signed message digest does not match file contents |

The original comes from the [RankFTW release archive](https://github.com/RankFTW/rhi-repo/releases/download/dlssnr-310.8.0/nvngx_dlssnr_310.8.0.zip), already pinned in `config/downloads.json`. Its archive SHA-256 is `388c0a7912e15ec911b9c9e11a692142b11fe387ddf2b637d8c358138fffb3ac`.

The reference was obtained from the [RenoDX installer Streamline archive](https://github.com/yumlevi/renodx-dlss-installer/releases/download/latest/streamline.zip), member `streamline/nvngx_dlssnr.dll`. The downloaded archive is 144,023,101 bytes, SHA-256 `5389d164ef99a0e4aba5128da2e87d26de5833aeaf89bfeb0232cfdc8f7229a2`, GitHub asset ID `534399347`. The `latest` URL can change; these recorded checksums identify the exact files used.

A [first-hand installer issue](https://github.com/yumlevi/renodx-dlss-installer/issues/1) reports the same two hashes and signature mismatch. The [signature-repair project's documentation](https://github.com/kayle2203/dlssnr-signature-repair/blob/main/README.md) also identifies the signed original. Those reports led to this investigation; the results above were reproduced locally with `osslsigncode 2.14`. No repair tool or NVIDIA DLL was executed.

## Weight comparison

The entire `WEIGHTS_HT` resource is **byte-identical** across both DLLs:

- Size: **147,695,410 bytes**.
- SHA-256: **`836f445d06ecd2e59bb9f17b84b91c143396fd76ccda1c9dc7fe81d5edd548f4`**.
- Packed tensor count: **153** in each file.

The complete `.rsrc` sections also match. The DLLs differ at 12,318,347 byte positions in `.text` and `.data`; this is more than a certificate or header change. This comparison does not establish why those sections were modified.

Our existing extracted package and all generated model checksums remain unchanged. The fork adds the signed original to the CLI's known-hash labels; no checksum requirement is relaxed and no inference or extraction algorithm changes. Matching source weights does not establish output parity between NVIDIA's runtime and the native MLX implementation.

## Reproduce locally

The comparison-only download is kept at `artifacts/dll-audit/nvngx_dlssnr-reference.dll`; bootstrap continues to fetch only the signed original. From the project root, with both files present:

```sh
brew install osslsigncode
osslsigncode verify -in models/sources/nvngx_dlssnr.dll
# The next command is expected to fail with a message-digest mismatch.
osslsigncode verify -in artifacts/dll-audit/nvngx_dlssnr-reference.dll
```

Verify the exact file identities before comparing resources:

```sh
uv run --frozen python - <<'PY'
import hashlib
from pathlib import Path
from mlxdlss.tools.extract_dlssnr_weights import extract_pe_resource, parse_weight_map

files = {
    "models/sources/nvngx_dlssnr.dll": "e16bcf15e16e13f527491cdf7845b2fe6521a738d8f7c9c721866a8496e1fc8e",
    "artifacts/dll-audit/nvngx_dlssnr-reference.dll": "ceb6432f6fbdf44d886014bcd47241932bf8b67439feef9bbdd0961436662650",
}
resources = []
for path, expected in files.items():
    data = Path(path).read_bytes()
    assert hashlib.sha256(data).hexdigest() == expected, path
    resource = extract_pe_resource(data)
    assert len(resource) == 147695410
    assert hashlib.sha256(resource).hexdigest() == "836f445d06ecd2e59bb9f17b84b91c143396fd76ccda1c9dc7fe81d5edd548f4"
    assert len(parse_weight_map(resource)) == 153
    resources.append(resource)
assert resources[0] == resources[1]
print("Exact DLL identities verified; WEIGHTS_HT is byte-identical, 153 packed tensors.")
PY
```

Local evidence: `artifacts/dll-audit/comparison.json`, `downloaded-signature.log` and `upstream-reference-signature.log` in that directory. The DLLs, archives, weights and local logs remain excluded from Git.
