# GitHub-to-Slurm (`gh2slurm`):

**GitHub Issues as a Slurm Job Queue**

A pattern for using GitHub Issues as a persistent, human-readable job queue that triggers work on a Slurm cluster from GitHub Actions.

> This repo is a **template/example** — not a ready-to-run codebase. Fork it, adapt the Slurm scripts to your workflow, point the broker at your GitHub queue repo, and submit. Everything here is illustrative; swap each piece for your own.

## Overview

This project implements a job queue where:
- GitHub issues represent work items. They can be created via a manual GitHub action using `workflow_dispatch`
- A recurring (chained) Slurm job acts as a broker to poll the queue and process items
- Results are tracked through issue labels and comments

## Who is this for?

**HPC users**, not cluster admins. You don't need admin privileges to set this up — just a GitHub account and access to a Slurm cluster. All jobs run as your user account.
If you can submit Slurm jobs from the command line, you can use this.

## What it's not

This is **not** a "run generic GitHub Actions on Slurm" system, such as [gha-slurm](https://github.com/ripley-cloud/gha-slurm) or [slurm-gha](https://github.com/WATonomous/slurm-gha). In those projects, you upload a full `.github/workflows/*.yml` and the Slurm cluster executes every step inside containers — the cluster becomes an Action runner.

Here, the workflow already lives **on the cluster** as regular Slurm scripts. The GitHub issue is just a lightweight trigger with minimal input — typically a commit hash and a few parameters. The actual workflow (e.g. build → benchmark → results) can be hidden away on the cluster; you never see the individual Slurm scripts from GitHub unless you want to.

### Security note

Supply chain risk is low because you're not pulling arbitrary action code into your cluster.
You're passing a small JSON payload to scripts that already exist.

Just take care in how the JSON payload is processed, and limit who can create issues via repo-level access control, to prevent arbitrary code/parameter injection.

## Key Design Decisions

- **Issues as queue items**: Human-readable, easy to inspect
- **State tracking**: Tracked via labels on the issue:

    | State                 | Label                      |
    | ---------------------- | --------------------------- |
    | Unclaimed              | *(none)*                   |
    | Claimed / in progress  | `running`                  |
    | Succeeded              | *(none — issue is closed)* |
    | Failed                 | `failed`                   |

(These are in addition to a label identifying them as belonging to the "queue", as well as a label indicating the target cluster).

- **Separate queue repo (recommended)**: Keeps your main project's issue tracker clean, and keeps the access-control boundary for "who can trigger cluster jobs" separate from your code repo's normal contributor access. Not required — issues can be created in the same repo — but a dedicated queue repo makes it easier to lock down who can create issues.
- **Self-chaining polls**: Each polling job schedules the next via `--dependency=afterok`. This replaces what would otherwise be a long-running daemon on the head node — many clusters don't reliably support those, since login nodes often get rebooted for maintenance and long-running processes are cleaned up automatically. A chained Slurm job survives reboots naturally because each link is a proper Slurm job, not a background process.
- **Effective cron replacement**: Many compute clusters don't have cron enabled; the poll loop gives you scheduled work without relying on cron
- **No SSH credentials needed**: The queue is polled from inside the cluster using a GitHub App, rather than connecting into the cluster from outside — no need to upload user SSH keys to GitHub Actions secrets, or create a restricted SSH key for external access
- **GitHub App authentication**: We authenticate as a GitHub App, not a user. Apps have their own identity, can be installed on specific repos with scoped permissions, and mint short-lived installation tokens (~1 hour) — so you don't need to share a personal access token or user credentials. See [About creating GitHub Apps](https://docs.github.com/en/apps/creating-github-apps/about-creating-github-apps/about-creating-github-apps) for details.
- **User-level operation**: Jobs run as your Slurm user

## Setup

### 1. Create a GitHub App

1. Go to **Settings → Developer settings → GitHub Apps** (or org-level at `https://github.com/organizations/<org>/settings/apps`).
2. Click **New GitHub App**. Fill in:
   - **Name**: e.g. `gh2slurm`
   - **Homepage URL**: can be anything (often the repo URL)
   - **Webhook**: uncheck "Active". The broker polls; it doesn't listen for webhook deliveries, and with no URL configured GitHub won't attempt any.
3. Under **Repository Permissions**, grant:
   - **Issues** → Read and write
4. Click **Create App**. Note the **App ID**.
5. Under **Private keys**, click **Generate a private key**. Save the `.pem` file somewhere accessible from the cluster — treat it like any other credential: `chmod 600`, keep it out of the queue repo and out of version control entirely, and don't put it anywhere world-readable on shared filesystems.

### 2. Install the App on the queue repo

1. In the App's settings, click **Install App** (left sidebar).
2. Choose the target repo (or an org to install on all repos).
3. After install, grab the **Installation ID** from the URL — it's the number after `/installations/` (e.g. `https://github.com/settings/installations/123456789` → `123456789`).

### 3. Install CLI tools on the cluster

```bash
./bin/install_github_cli_tools_linux_amd64               # install both (default)
./bin/install_github_cli_tools_linux_amd64 --gh-cli-only # install only gh CLI
./bin/install_github_cli_tools_linux_amd64 --token-only  # install only gh-token
```

Single installer with optional flags to pick which tool(s) to install. Both binaries land in `./bin`, which is also the default `$GH_CLI_BIN`. Alternatively, if you already have the CLI tools installed, just ensure they're accessible by setting the correct `$GH_CLI_BIN`.

[`gh-token`](https://github.com/Link-/gh-token) mints short-lived GitHub App installation tokens from your `.pem` key. It's needed because installation tokens expire after about an hour — the broker and any long-running child jobs can generate their own token via `gh_setup` rather than trying to share one that might expire mid-job. If you'd rather not manage an extra binary, `bin/gh-token-bash` (bundled here) does the same JWT-generation-and-exchange using only `openssl`.

### 4. Configure the broker

Edit `gh2slurm` and set:

| Variable | Meaning |
|---|---|
| `RESUBMIT_FREQ` | How often to run the broker, e.g. `1week`, `1minute`; used directly by `sbatch --begin` to delay the start of the next poll job. Keep this reasonably conservative: GitHub App installation tokens are rate-limited (~5000 requests/hour), so a very tight interval across many queue repos or clusters can burn through that budget. |
| `CLUSTER_LABEL`     | Label on issues this broker should claim (e.g. `ozstar`) |
| `QUEUE_LABEL`       | Label that identifies queue items (default: `job-queue`) |
| `ISSUE_AUTHOR`      | Filter for issues written by this author |
| `GH_APP_ID`         | App ID from step 1 |
| `GH_APP_INSTALL_ID` | Installation ID from step 2 |
| `GH_APP_KEY`        | Path to the private key `.pem` file |
| `GH_REPO`           | Queue repo descriptor in the format `owner/repo` |
| `GH_CLI_BIN`        | Directory containing `gh` and `gh-token` (default: `$PWD/bin`) |

### 5. Point the broker at your workflow

By default the broker submits `./example/workflow/workflow-manager.sh`. Replace it with your own workflow script — near the bottom of `gh2slurm`, in the block that submits the manager job:

```bash
# In gh2slurm, change:
WORKFLOW_RUNDIR="$PWD/example/workflow/runs"
WORKFLOW_SCRIPT="$PWD/example/workflow/workflow-manager.sh"
```

Slurm will change directory to `$WORKFLOW_RUNDIR` before submitting `$WORKFLOW_SCRIPT`.

### 6. Submit the broker

```bash
sbatch gh2slurm
```

The first poll runs immediately; each subsequent poll is chained via `--dependency=afterok` so the queue runs continuously.

## Components

### 1. Queue Workflow (`.github/workflows/queue.yml`)

This file is a **working example** of how to create queue items from a GitHub Action. It's triggered here via `workflow_dispatch` and creates one issue per cluster with work parameters in the body.

In a real setup, you'll typically have two repos:

| Repo           | Purpose                                  |
| -------------- | ----------------------------------------- |
| **Queue repo** | Holds issues and is polled by the broker |
| **Code repo**  | Holds the code you want to benchmark     |

In the code repo, a workflow — often on a `schedule` cron trigger — creates issues **in the queue repo** (via the GitHub API, authenticated with a GitHub App installation token). Each issue body is JSON. For example:

```json
{
  "commit": "a1b2c3d",
  "run_number": "42",
  "param1": "value"
}
```

> **Note**: If you're creating issues from a workflow in a *different* repo, use the [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token) action to generate an installation token. This is cleaner than manually generating the JWT + exchanging it yourself — the action handles both steps and returns the token as an output you can pass to `gh` or `curl`.

### 2. Broker (`gh2slurm`)

A Slurm job that:

- Polls the GitHub API for unclaimed issues matching its cluster label
- Claims issues by adding the `running` label
- Submits workflow to the cluster
- Updates issue status

Uses `--dependency=afterok` to chain poll jobs, creating a self-sustaining loop.

The broker relies on:

- `gh_setup` function: validates environment, generates a GitHub App JWT, exchanges it for an installation access token via the `gh-token` CLI
- `GH_EXPORT_LIST`: a comma-separated list of env vars, and the `gh_setup` function itself, that get forwarded to child Slurm jobs so they can generate their own tokens — necessary because installation tokens expire (~1hr) and a child job may easily outlive the token the broker started with

### 3. Workflow (`example/workflow/workflow-manager.sh`)

In our example, the workflow:
- takes the issue as input
- validates the JSON payload (commit hash format, run number is numeric, etc)
- validates the downloaded tarball for path-traversal entries before extracting
- creates a unique run directory
- downloads the example code at a specific commit, as specified in the issue body (JSON payload)
- and submits a chain of three dependent Slurm jobs:

1. **`build.sh`** — compiles `src/helloworld.c` via Make
2. **`benchmark.sh`** — runs the binary, times it, saves output to `timings.txt` (runs after build job succeeds)
3. **`results.sh`** — posts the timing results back to the issue as a comment (runs after benchmark succeeds)

A fourth inline `report` job is then submitted via `--dependency=afterany` so it runs regardless of whether any of the three work jobs failed. It gathers parent job states via `sacct`, posts a summary comment, and either closes the issue or marks it `failed`. It's a reporting step layered on top of the workflow, not part of the workflow itself.

Dependencies between jobs are specified using `sbatch --dependency` flags.

### 4. Supporting files

- `bin/install_github_cli_tools_linux_amd64` — combined installer for `gh` and `gh-token` CLIs (with `--gh-cli-only` and `--token-only` flags)
- `bin/gh-token-bash` — pure-bash fallback that generates a GitHub App JWT using `openssl` and exchanges it for an installation token (no extra binary needed)

## Architecture

```
GitHub Actions
     │
     │  creates issue per cluster (queue.yml)
     ▼
Slurm broker (gh2slurm) — short-lived
     │
     │  resubmits itself via --dependency=afterok
     │  polls queue → claims issue (adds `running` label)
     │  submits one "manager" workflow job
     ▼
workflow-manager.sh — manager
     │
     │  sets up run dir, downloads code,
     │  submits 3 dependent Slurm jobs:
     ▼
  build.sh ──afterok──► benchmark.sh ──afterok──► results.sh
     │                      │                        │
     ▼                      ▼                        ▼
  [slurm job]           [slurm job]             [slurm job] — posts timing
──────────────────────────────────────────────────────────────────────────
                                 │
                              afterany
                                 │
                                 ▼
                        [reporting slurm job]
   - gathers sacct states for all 3 parent jobs,
   - posts summary,
   - closes or marks failed
```

Key points:

- The **broker** (`gh2slurm`) is short-lived — it only claims an issue and submits the manager workflow, then exits. It doesn't do any actual work.
- The broker **resubmits itself first** via `--dependency=afterok`, before it even looks for work — so the next poll is queued immediately, ensuring the queue keeps moving even if the manager or work jobs fail downstream. However, any failure in `gh_setup` will kill the chain.
- The **manager** (`workflow-manager.sh`) runs in its own Slurm job and handles payload validation, tarball extraction, run-directory setup, and submission of the three work jobs (see Components above).
- `results.sh` is the last step of the workflow — it posts only the timing output.
- `report` is a separate reporting job layered on top of the workflow. It runs unconditionally (`afterany`) so that failures of any workflow job are still reported to the issue.
