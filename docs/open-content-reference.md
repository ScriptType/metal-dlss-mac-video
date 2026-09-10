# Natural-scene reference input

The optional [source catalog](../config/open-content.json) pins public Netflix Open Content files for local tests. [Netflix's catalog](https://sites.google.com/netflix.com/opencontent/home) publishes Meridian and the HDR re-grade of Blender's Cosmos Laundromat under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The catalog retains attribution and source URLs. Downloaded images, movies and derived pixels remain outside Git.

## Source qualification

The advertised P3/PQ MP4 previews do not provide a sufficient encoded-colour contract:

| Download | Actual encoding | Limitation |
|---|---|---|
| Meridian HDR-labelled preview | 3840×2160, H.264 8-bit 4:2:0, 60000/1001 fps | No primaries, transfer or YCbCr matrix tags; video only |
| Cosmos HDR-labelled preview | 2048×858, H.264 8-bit 4:2:0, 24000/1001 fps | No primaries, transfer or YCbCr matrix tags; video only |

Both are marked ineligible for HDR qualification. Their filenames do not resolve the missing YCbCr interpretation, and the downloader does not add colour tags.

The temporal fixture instead uses 48 original RGB HALF EXR files from Cosmos Laundromat, frames 10000–10047. Each file has a pinned SHA256 and size. The EXR headers report 2048×858, square pixels and `framesPerSecond=2997/125`; they omit chromaticities and transfer metadata. The initial derivative records an explicit D65 assumption. The publisher metadata match below now supplies source-specific support for that white point, while the original derivative and capture hashes remain unchanged.

## Publisher metadata match

Netflix's [asset README](https://s3.amazonaws.com/download.opencontent.netflix.com/TechblogAssets/README.txt), linked from its [production article](https://netflixtechblog.com/engineers-making-movies-aka-open-source-test-content-f21363ea3781), identifies the 4,000-cd/m² Cosmos Video Display Master as output-referred RGB with P3-D65 primaries, PQ transfer and full-range half-float EXR storage. This documentation points to a separate VDM directory rather than the older download paths used by the fixture.

The [metadata verification](evidence/cosmos-publisher-metadata.json) matches all 48 pinned legacy files against that VDM directory's publisher checksum list: each corresponding frame index has the same size and MD5, and each local SHA256 still matches the source catalog. The evidence retains the README and checksum-list URLs, bytes and SHA256 values. This is a match to publisher checksum metadata, not an independent download of the second image sequence or display calibration.

The README calls the frame rate 24 fps; the EXRs contain the exact fraction 2997/125, or 23.976 fps. The derivative preserves the embedded rate and duration 125/2997 rather than silently changing timing. The documentation does not explain this discrepancy or specify how negative and above-one PQ values should be interpreted. D65 identification therefore does not validate the selected out-of-domain PQ extension. Existing manifests retain their original assumption labels for reproducibility; this follow-up evidence does not rewrite them.

## Prepare the float sequence

```sh
# Downloads approximately 507 MB of original EXR files, without the MP4 previews.
python3 scripts/fetch-open-content.py cosmos-exr-dial

uv run --frozen --group reference python scripts/prepare-cosmos-reference.py \
  --assume-p3-d65 --extend-pq-domain \
  --output artifacts/cosmos-reference-input-box
```

The converter uses the locked [OpenEXR reader](https://openexr.com/en/latest/python.html) to preserve HALF samples, applies the selected PQ inverse and P3-D65→BT.2020-D65 matrix, then downsamples to 320×134 with floating-point box averaging. It writes interleaved little-endian RGB Float32 in nits without component clipping. Every frame retains its source index, source/output hashes, exact assigned relative PTS/duration and domain statistics. The output manifest is published only after the whole sequence completes; an existing output directory is never overwritten.

The source includes negative and above-one encoded components. `--extend-pq-domain` explicitly selects an odd-symmetric inverse below zero and analytic continuation above one. These domains are counted; their derived values are not a claim about standard-range PQ mastering or physical luminance. Without this option, out-of-range input is rejected. Timing is assigned from EXR frame indices and their exact declared rate, with no borrowed MP4 timestamps or audio. The first frame starts cold; no preroll is implied.

The [input evidence](evidence/m3-cosmos-reference-input.json) records 48 finite frames, 24,698,880 output bytes, and values from −0.04922 to 13,333.18 nits under that selected interpretation. Box averaging avoids the large negative ringing observed in the retained Lanczos experiment. These are small diagnostic inputs for temporal comparisons, not full-resolution quality, native decode or display-accuracy results.

An independent format check found OpenEXR and FFmpeg's direct `gbrpf16le` output identical for frame 10000. Forcing that FFmpeg invocation to `gbrpf32le` changed all components and clipped its 1,066 above-one components to at most one. The reference converter uses OpenEXR directly; the evidence retains both results and the tested FFmpeg identity.
