# Configuration

System-specific settings and building.

| | |
|---|---|
| [machines.toml](machines.toml) | the machines the demos and benchmarks run on, and the ports they are reached at |
| [xbuild/](xbuild/) | the cross-build tree that produces the stacks remote nodes deploy |

`machines.toml` holds one table per machine: the SSH host, the cross-compilation target, the bundle
it deploys, the executor's environment, and the transport backend's `key=value;...` config string.
`demos/placement.py` and `benchmarks/placement.py` both read it and assemble one dictionary per
node, each adding the nodes only it uses. Two environment variables move the paths it names:

| | |
|---|---|
| `CATALYST_ROOT` | the local Catalyst build tree, default `~/catalyst` |
| `BACKLINE_BUNDLES` | the cross-built bundles a remote node deploys, one subdirectory per machine. Defaults to `xbuild/build/bundles`, where `make bundle` publishes every bundle it builds |

Each bundle is one machine's stack, placed in that machine's workspace before its executor starts.

`xbuild/` produces the bundles the demos deploy, `vpk-bundle` and `threadripper-bundle`, so
`BACKLINE_BUNDLES` can point at its output rather than at a tree built elsewhere.
[`../INSTALL.md`](../INSTALL.md) has the sequence.

A relative `bundles` path is resolved against the repository root rather than the working
directory, so the committed default works from `demos/` and from `benchmarks/` alike. An absolute
`BACKLINE_BUNDLES` still overrides it outright.
