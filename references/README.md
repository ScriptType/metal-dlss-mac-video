# Reference checkouts

`python3 scripts/fetch-sources.py` fetches the three Windows reference projects at the exact revisions from the plan. They are ignored local checkouts, not linked dependencies. They support future cache, synchronization, resource-lifetime, and NVIDIA comparison work. No Windows executables, driver installers, or CUDA toolkits are installed on this Mac.

Repository URLs and commits are in `config/sources.json`; retain attribution and review each component's licence before copying implementation code.
