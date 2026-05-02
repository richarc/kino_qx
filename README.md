# Kino.Qx

A [Livebook](https://livebook.dev) [Smart Cell](https://hexdocs.pm/kino/Kino.SmartCell.html)
for the [Qx Portal](https://qxportal.dev).

Browse the snippets you've saved on the portal, pick one from a
dropdown, and inject the OpenQASM 3.0 (or converted Elixir/Qx) source
straight into a notebook cell.

## Status

**Pre-alpha.** v0.1 is the first published release. The portal-side
JSON API is locked at `/api/v1` — see the
[API reference](https://qxportal.dev/api/v1/docs).

## Installation

In a Livebook setup cell:

```elixir
Mix.install([
  {:kino_qx, "~> 0.1"}
])
```

After the cell runs, click the **+ Smart** button at the bottom of any
notebook cell, choose **Qx Snippet**, and follow the prompts.

## Configuration

The cell needs two things:

1. **Your `qx_live_*` API token.** Get one at the portal's dashboard:
   *Dashboard → API Keys → Generate Key*. The raw token is shown
   once — copy it then. Pasted into the cell's "Token" textbox.
2. **The portal URL.** Defaults to `https://qxportal.dev`. Override
   in the cell's "Portal URL" textbox if you're running self-hosted
   or staging.

The token is stored only in transient cell state and **never**
serialized into the `.livemd` file. Sharing a notebook does not leak
your token.

## Compatibility

| `kino_qx` | Kino    | Elixir   |
|----------:|---------|----------|
| 0.1.x     | ~> 0.19 | >= 1.17  |

## Troubleshooting

| Symptom              | Likely cause                                                  |
|----------------------|---------------------------------------------------------------|
| `unauthorized` (401) | Token is wrong, revoked, or for a different portal            |
| Empty dropdown       | You haven't saved any snippets to the portal yet              |
| `rate_limited` (429) | More than 60 requests per minute on this key — wait + retry   |
| Network timeout      | Wrong portal URL, or the portal is unreachable from this host |

## License

[Apache 2.0](LICENSE).
