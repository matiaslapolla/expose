# expose

One command to put a dev server on your [Tailscale](https://tailscale.com) tailnet over HTTPS.
If the server is not running yet, `expose` starts it first.

```console
$ cd ~/code/my-next-app
$ expose
starting in /home/me/code/my-next-app: pnpm run dev --port 3000
logs: tmux attach -t expose-3000
https://devbox.tail1234.ts.net:13000  ->  :3000
http://devbox:3000  (direct, no TLS)
```

It is made for working on a remote dev box (a desktop, a home server, a VM) from a laptop over SSH:
the code and the dev server stay on the box, and the browser on the laptop opens the tailnet URL.
You stop typing `tailscale serve --bg --https=… http://127.0.0.1:…` for each repo and remembering which port went where.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/matiaslapolla/expose/main/install.sh | sh
```

This copies `bin/expose` to `~/.local/bin` (set `PREFIX` to change it). Or clone the repo and symlink `bin/expose` onto your `PATH`.

Requirements: bash 3.2+, `jq`, Tailscale with [HTTPS certificates](https://tailscale.com/kb/1153/enabling-https) enabled,
and `tmux` (optional). Works on Linux (`ss`) and macOS (`lsof`).

On Linux, `tailscale serve` needs root unless your user is the operator. Run this once:

```sh
sudo tailscale set --operator=$USER
```

## Usage

```text
expose                 expose the dev server of the current dir, starting it if needed
expose <dir>           same, for <dir>
expose <port>          expose <port> if something listens there, else start the current dir's server on it
expose <dir> <port>    start <dir>'s dev server on <port> if it is not running, then expose it
expose ls              served ports and running dev servers
expose off <port>      stop exposing <port>; stops the dev server too if expose started it
expose config [dir]    effective configuration and the start command for [dir]
expose init            write a commented .expose file in the current dir
```

`expose` is idempotent. If the dir already has a running server, `expose` reuses it.

### How it works

1. **Find the server.** `expose` looks for a listening process whose working directory is the project dir.
   This is how it knows that `:3201` belongs to `apps/web`.
2. **Start the server if there is none.** It picks the first free port from `EXPOSE_PORT_MIN`, builds the start command and runs it in a
   tmux session (`expose-<port>`) or in the background. It then waits until the server listens.
3. **Serve it.** It runs `tailscale serve --bg --https=<port + 10000> http://127.0.0.1:<port>`.
   The HTTPS port is offset because the dev server already holds `<port>` on every interface.

The start command, by default, is the `dev` script of `package.json`. `expose` runs it with the package manager that matches the lockfile
(pnpm, bun, yarn or npm) and passes `--port <port>`. Next.js, Vite, Astro, Nuxt and SvelteKit all accept `--port`.
For anything else, set `EXPOSE_CMD`.

## Configuration

Settings are `KEY=value` lines. Later layers win:

1. built-in defaults
2. `~/.config/expose/config` (global)
3. `<project>/.expose` (the project dir, or the git root)
4. `EXPOSE_*` environment variables

The files are parsed, not sourced. Run `expose config` to see the result and where it came from.

| Key | Default | Meaning |
| --- | --- | --- |
| `EXPOSE_CMD` | _(unset)_ | Start command. `{port}` is replaced with the port. Unset = the `package.json` script below. |
| `EXPOSE_SCRIPT` | `dev` | `package.json` script to run. |
| `EXPOSE_PORT_FLAG` | `--port` | Flag that passes the port to that script. |
| `EXPOSE_MODE` | `serve` | `serve` = HTTPS through `tailscale serve`. `direct` = only print `http://<host>:<port>`. |
| `EXPOSE_HTTPS_OFFSET` | `10000` | HTTPS port = dev port + offset. |
| `EXPOSE_TARGET_HOST` | `127.0.0.1` | Host that `tailscale serve` proxies to. Use `[::1]` for servers that bind IPv6 localhost only. |
| `EXPOSE_PORT_MIN` / `EXPOSE_PORT_MAX` | `3000` / `9999` | Range for picked ports and for `expose ls`. |
| `EXPOSE_RUNNER` | `tmux` if installed, else `background` | `background` writes logs to `~/.local/state/expose/<port>.log`. |
| `EXPOSE_WAIT` | `60` | Seconds to wait for a started server to listen. |
| `EXPOSE_TAILSCALE` | `tailscale` | Tailscale CLI. On macOS it falls back to the app bundle binary. |

### Examples

```sh
# .expose in a Laravel app
EXPOSE_CMD=php artisan serve --port {port}

# .expose in a Django app
EXPOSE_CMD=uv run manage.py runserver {port}

# .expose for a script that is not called "dev"
EXPOSE_SCRIPT=start:web
EXPOSE_PORT_FLAG=-p

# ~/.config/expose/config: plain HTTP, no tailscale serve
EXPOSE_MODE=direct

# one-off override
EXPOSE_RUNNER=background expose 4000
```

## Gotchas

- **The framework rejects the host.** Some dev servers block requests for an unknown host. Allow your tailnet name:
  `allowedDevOrigins: ['devbox', 'devbox.tail1234.ts.net']` in `next.config`, `server.allowedHosts: ['.ts.net']` in Vite.
- **`direct` mode needs the server on all interfaces.** Next binds to all interfaces. Vite needs `--host`.
  `serve` mode works with localhost-only servers.
- **OAuth callbacks, `Secure` cookies, `crypto.subtle`, service workers** need HTTPS or `localhost`. `serve` mode gives you HTTPS.
- **`.expose` runs commands.** `EXPOSE_CMD` in a repo you cloned executes on `expose`, the same way its `package.json` scripts do on `npm run dev`.

## Development

```sh
./test/run.sh          # end-to-end tests against a stub tailscale (needs jq, python3, node; tmux optional)
shellcheck bin/expose install.sh test/run.sh
```

## License

MIT
