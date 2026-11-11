# k9s-config

[![CI](https://github.com/WillMatthews/k9s-config/actions/workflows/ci.yml/badge.svg)](https://github.com/WillMatthews/k9s-config/actions/workflows/ci.yml)

Give every Kubernetes context its own [k9s](https://k9scli.io/) background colour, so production looks different from dev before you delete the wrong pod.

The script takes one k9s skin, makes a copy of it for each colour you list with only the background changed, and points each context at its copy.
The write-up is on my blog: *K9s Per-Cluster Configuration*.

## Requirements

- [k9s](https://k9scli.io/topics/install/) 0.32.7 or newer
- [yq](https://github.com/mikefarah/yq#install) v4 by mikefarah (the Python `yq` is a different tool)
- `curl`
- bash 3.2 or newer, so the bash that ships with macOS is fine

With Homebrew: `brew install k9s yq`.

## Usage

1. Edit [`k9s-skins.yaml`](k9s-skins.yaml): choose a theme, the colours, and rules for which context gets which colour.
2. Close k9s, because it rewrites its config when it exits.
3. Run:

   ```sh
   ./k9s_configure.sh                # uses k9s-skins.yaml next to the script
   ./k9s_configure.sh my-skins.yaml  # or another config file
   ./k9s_configure.sh --refresh      # also download the base skin again
   ```

It's safe to run again after changing the config, or after adding contexts to your kubeconfig. Existing k9s settings are kept; only the `skin` values are set.

## Configuration

```yaml
theme: one-dark

colours:
  red: "#3f1f28"
  blue: "#1f283f"
  green: "#1f2f28"
  grey: "#2f2f2f"

contexts:
  - name: minikube         # exactly this context
    colour: green
  - match: "*prod*"        # a shell glob pattern
    colour: red
  - match: "*dev*"
    colour: blue

default: grey              # optional: contexts no rule matches
```

**theme** is a skin from [the k9s skins folder](https://github.com/derailed/k9s/tree/master/skins).
It must set its background with a `background: &background` anchor, because every other part of the skin that uses the background colour refers back to that one value.
The script stops with an error if the skin doesn't have one.
As of 10/11/2026 these skins do:

dracula, gruvbox-dark, gruvbox-dark-hard, gruvbox-light, gruvbox-light-hard, gruvbox-material-dark-hard, gruvbox-material-dark-medium, gruvbox-material-dark-soft, gruvbox-material-light-hard, gruvbox-material-light-medium, gruvbox-material-light-soft, kanagawa, modus-operandi, modus-operandi-deuteranopia, modus-operandi-tinted, modus-operandi-tritanopia, modus-vivendi, modus-vivendi-deuteranopia, modus-vivendi-tinted, modus-vivendi-tritanopia, monokai, nightfox, nord, one-dark, one-light, rose-pine, solarized-16, solarized-dark, solarized-light, vercel.

The default colours are dark tints, so use a dark skin with them or choose light colours for a light one.

The skin is downloaded from the k9s release that matches your installed version, so it only uses settings your k9s understands.
If the skin is newer than your k9s, or your version has no release tag, it comes from k9s's `master` branch instead.
A skin that's already installed is left alone unless you pass `--refresh`, so you can use your own edited copy.

**contexts** are rules, checked against every context in your kubeconfig (`$KUBECONFIG`, or `~/.kube/config`). The first rule that matches a context sets its colour.

- `name:` matches one context exactly. If that context isn't in your kubeconfig, it's configured anyway, so the skin is ready when it's added. Add `cluster:` if its cluster has a different name.
- `match:` is a shell glob pattern, such as `*prod*` or `aks-*-uk`.

Contexts that no rule matches get the **default** colour. Without a default, they're left alone.

k9s stores each context's settings under its cluster, so the script reads each context's cluster from your kubeconfig.

## What it writes

Paths come from `k9s info`. On Linux they are usually:

| File | Contents |
| --- | --- |
| `~/.config/k9s/skins/<theme>.yaml` | The base skin, downloaded if missing |
| `~/.config/k9s/skins/<theme>-<colour>.yaml` | One recoloured copy per colour |
| `~/.config/k9s/config.yaml` | `k9s.ui.skin: <theme>`, the default for contexts not configured |
| `~/.local/share/k9s/clusters/<cluster>/<context>/config.yaml` | `k9s.skin: <theme>-<colour>` |

`:` and `/` in cluster and context names become `-` in folder names, as k9s does it, so EKS ARN context names work.

## Tests

```sh
tests/run.sh          # all tests
tests/run.sh refresh  # only tests whose names contain "refresh"
```

The tests need only bash, yq and curl. Stubs in `tests/bin` stand in for `k9s` and `pgrep`, and skins come from `tests/fixtures`, so nothing touches your real k9s config or the network.
Set `TEST_BASH=/bin/bash` on macOS to run the script under bash 3.2.
CI runs shellcheck, and runs the tests on Linux and on macOS with bash 3.2.
