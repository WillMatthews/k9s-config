# k9s-config

Give every Kubernetes context its own [k9s](https://k9scli.io/) background colour, so production looks different from dev before you delete the wrong pod.

The script takes one k9s skin, makes a copy of it for each colour you list with only the background changed, and points each context at its copy.
The write-up is on my blog: *K9s Per-Cluster Configuration*.

## Requirements

- [k9s](https://k9scli.io/topics/install/) 0.32.7 or newer
- [yq](https://github.com/mikefarah/yq#install) v4 by mikefarah (the Python `yq` is a different tool)
- `curl`

With Homebrew: `brew install k9s yq`.

## Usage

1. Edit [`k9s-skins.yaml`](k9s-skins.yaml): choose a theme, the colours, and the colour for each context.
2. Close k9s, because it rewrites its config when it exits.
3. Run:

   ```sh
   ./k9s_configure.sh                # uses k9s-skins.yaml next to the script
   ./k9s_configure.sh my-skins.yaml  # or another config file
   ```

It's safe to run again after changing the config. Existing k9s settings are kept; only the `skin` values are set.

## Configuration

```yaml
theme: one-dark

colours:
  red: "#3f1f28"
  blue: "#1f283f"

contexts:
  - name: prod
    colour: red
  - name: dev
    colour: blue
  - name: staging              # cluster is optional; it's looked up in
    cluster: staging-cluster   # your kubeconfig when left out
    colour: blue
```

**theme** is a skin from [the k9s skins folder](https://github.com/derailed/k9s/tree/master/skins).
It must set its background with a `background: &background` anchor, because every other part of the skin that uses the background colour refers back to that one value.
The script stops with an error if the skin doesn't have one.
As of 10/11/2026 these skins do:

dracula, gruvbox-dark, gruvbox-dark-hard, gruvbox-light, gruvbox-light-hard, gruvbox-material-dark-hard, gruvbox-material-dark-medium, gruvbox-material-dark-soft, gruvbox-material-light-hard, gruvbox-material-light-medium, gruvbox-material-light-soft, kanagawa, modus-operandi, modus-operandi-deuteranopia, modus-operandi-tinted, modus-operandi-tritanopia, modus-vivendi, modus-vivendi-deuteranopia, modus-vivendi-tinted, modus-vivendi-tritanopia, monokai, nightfox, nord, one-dark, one-light, rose-pine, solarized-16, solarized-dark, solarized-light, vercel.

The default colours are dark tints, so use a dark skin with them or choose light colours for a light one.

**contexts** are matched by name against your kubeconfig (`$KUBECONFIG`, or `~/.kube/config`).
k9s stores each context's settings under its cluster, so the script looks the cluster up there.
If the context isn't in your kubeconfig yet, give `cluster:` yourself; otherwise it's assumed to match the context name.

## What it writes

Paths come from `k9s info`. On Linux they are usually:

| File | Contents |
| --- | --- |
| `~/.config/k9s/skins/<theme>.yaml` | The base skin, downloaded if missing |
| `~/.config/k9s/skins/<theme>-<colour>.yaml` | One recoloured copy per colour |
| `~/.config/k9s/config.yaml` | `k9s.ui.skin: <theme>`, the default for contexts not listed |
| `~/.local/share/k9s/clusters/<cluster>/<context>/config.yaml` | `k9s.skin: <theme>-<colour>` |

`:` and `/` in cluster and context names become `-` in folder names, as k9s does it, so EKS ARN context names work.
