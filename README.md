# FCP Pods Dashboard

A lightweight web dashboard for viewing pods in a GCP/GKE cluster without
logging in and running `kubectl` commands by hand each time.

It replaces this manual flow:

```
gcloud auth login
gcloud config set project <project>
gcloud container clusters get-credentials <cluster> --region <region> --project <project>
kubectl config set-context --current --namespace=<ns>
kubectl get pods
kubectl logs -f <pod>
```

…with a single browser tab.

## What's inside

| File              | Purpose                                                |
| ----------------- | ------------------------------------------------------ |
| `public/`         | Single-page UI (HTML/CSS/JS, no frameworks)            |
| `server.ps1`      | PowerShell HTTP server (Windows + cross-platform pwsh) |
| `server.sh`       | Bash + `nc` HTTP server (Linux / macOS fallback)       |
| `start.cmd`       | Windows launcher — runs `server.ps1`, opens browser    |
| `start.sh`        | Unix launcher — prefers `pwsh`, falls back to bash     |
| `Install.cmd`     | Placeholder install script (Windows)                   |
| `install.sh`      | Placeholder install script (Linux / macOS)             |
| `config.json`     | Auto-saved (project / cluster / region / namespaces)   |

No `npm install`, no `pip install`, no compilation step.

## Dependencies

* **`gcloud` and `kubectl`** on `PATH`. If either is missing, the dashboard
  surfaces a banner with a one-click button that runs `Install.cmd` /
  `install.sh` — see "Wiring the installer" below.
* **Windows:** PowerShell 5.1 (built in) or 7+. Nothing else.
* **Linux / macOS:** either `pwsh` (recommended, full feature parity) **or**
  `bash` + `nc` (the bash server). Both are usually preinstalled on Linux/macOS.

## Run it

### Windows

```bat
cd fcp-dashboard
start.cmd
```

This launches `server.ps1` on `http://localhost:8765` and opens your default
browser. Change the port with `start.cmd 9000`.

### Linux / macOS

```bash
cd fcp-dashboard
chmod +x start.sh server.sh install.sh
./start.sh
```

If `pwsh` (PowerShell 7) is installed, the launcher uses `server.ps1` for the
best experience. Otherwise it falls back to `server.sh` (bash + nc).

## Using the dashboard

1. Click **Login** — runs `gcloud auth login`. Your default browser opens a
   Google login page. Once you finish, the auth pill on the top right turns
   green.
2. Fill in **Project**, **Cluster**, **Region** and click **Connect**. This
   runs `gcloud config set project` and `gcloud container clusters get-credentials`.
   Values persist in `config.json`.
3. Type a **Namespace** and click **Load pods**. Past namespaces are remembered
   and offered as suggestions.
4. Use the **filter** box to narrow the table, the **Logs** button for `kubectl
   logs --tail=N` (with optional live polling), and **Describe** for `kubectl
   describe pod`.
5. Tick **Auto-refresh** for periodic reloads. Use the **kubectl context**
   dropdown to switch between clusters you've already authenticated against.

## Wiring the installer

If `gcloud` or `kubectl` aren't on `PATH`, the dashboard shows a yellow banner
with a **Run installer** button. That button calls:

* `Install.cmd` on Windows
* `install.sh` on Linux / macOS

Both ship as **placeholders**. Open the file and replace the body with whatever
your team uses today (silent MSI, `choco install`, `brew install`, a copy from
a network share, etc.). The dashboard treats exit code `0` as success and
displays stdout / stderr back in the UI.

## Notes & limits

* All commands run on the machine the server is on. No remote control, no
  secrets stored — the dashboard reuses your existing `gcloud` / `kubectl`
  auth on disk (same as if you'd run the commands yourself).
* The server only binds to `localhost` by default; nothing is exposed to the
  network.
* "Live follow" on the Logs panel polls the API every ~3 seconds (rather than
  streaming) to keep the server tiny. For long-running tails, just run
  `kubectl logs -f` in a terminal as before.
* The bash server is single-connection at a time. The PowerShell server is also
  sequential. For a personal dashboard this is fine; do not put it behind a
  load balancer.
