# GitHub-to-Slurm (`gh2slurm`):

**GitHub Issues as a Slurm Job Queue**

A pattern for using GitHub Issues as a persistent, human-readable job queue that triggers work on a Slurm cluster from GitHub Actions.

## Overview

This project implements a job queue where:
- GitHub Actions creates issues to represent work items
- A Slurm broker polls the queue and processes items
- Results are tracked through issue labels and comments

## Key Design Decisions

- **Issues as queue items**: Human-readable, easy to inspect/debug
- **State tracking**: Labels: `running` and `failed`. Claimed issues get the `running` label; completed issues are closed; failed issues get the `failed` label. An unclaimed issue has neither label.
- **Self-chaining polls**: Each poll job schedules the next via `--dependency=afterok`
- **No SSH credentials needed**: Polling via GitHub App token avoids putting SSH keys on the cluster or managing SSH config — the broker just needs API access
- **Effective cron replacement**: Many compute clusters don't have cron enabled; the poll loop gives you scheduled work without relying on cron
- **Separate queue repo**: Keeps main project issues clean (recommended)

## Setup

### 1. Create a GitHub App

1. Go to **Settings → Developer settings → GitHub Apps** (or org-level at `https://github.com/organizations/<org>/settings/apps`).
2. Click **New GitHub App**. Fill in:
   - **Name**: e.g. `gh2slurm`
   - **Homepage URL**: can be anything (often the repo URL)
   - **Webhook URL**: leave blank — the broker polls; it doesn't need webhooks
3. Under **Permissions**, grant:
   - **Issues** → Read and write
4. Under **Subscribe to events**, check **Issues** (optional — useful if you later add webhook-driven behaviour).
5. Click **Create App**. Note the **App ID**.
6. Under **Private keys**, click **Generate a private key**. Save the `.pem` file somewhere accessible from the cluster.

### 2. Install the App on the queue repo

1. In the App's settings, click **Install App** (left sidebar).
2. Choose the target repo (or an org to install on all repos).
3. After install, grab the **Installation ID** from the URL — it's the number after `/installations/` (e.g. `https://github.com/settings/installations/131916569` → `131916569`).

### 3. Install CLI tools on the cluster

```bash
./install-gh-cli_linux_amd64     # puts `gh` in ./bin
./install-gh-token_linux_amd64   # puts `gh-token` in ./bin
```

Both scripts download the latest release and place binaries in `./bin`, which is also the default `$GH_CLI_BIN`.

### 4. Configure the broker

Edit `gh2slurm` and set:

| Variable | Meaning |
|---|---|
| `RESUBMIT_FREQ` | How often to re-poll when the queue is empty (Slurm `--begin` offset, e.g. `1week`, `1minute`) |
| `CLUSTER_LABEL` | Label on issues this broker should claim (e.g. `ozstar`) |
| `QUEUE_LABEL` | Label that identifies queue items (default: `job-queue`) |
| `GH_APP_ID` | App ID from step 1 |
| `GH_APP_INSTALL_ID` | Installation ID from step 2 |
| `GH_APP_KEY` | Path to the private key `.pem` file |
| `GH_REPO` | `owner/repo` of the queue repo |
| `GH_CLI_BIN` | Directory containing `gh` and `gh-token` (default: `$PWD/bin`) |

### 5. Point the broker at your workflow

By default the broker submits `./example_workflow/example_workflow.sh`. Replace it with your own workflow script:

```bash
# In gh2slurm, change:
--chdir ./example_workflow \
./example_workflow/example_workflow.sh "$ISSUE"
```

### 6. Submit the broker

```bash
sbatch gh2slurm
```

The first poll runs immediately; each subsequent poll is chained via `--dependency=afterok` so the queue runs continuously.

## Components

### 1. Queue Workflow (`.github/workflows/queue.yml`)

This file is a **working example** of how to create queue items from a GitHub Action. It's triggered here via `workflow_dispatch` and creates one issue per cluster with work parameters in the body.

In a real setup, you'll typically have two repos:

| Repo | Purpose |
|---|---|
| **Queue repo** (this one) | Holds issues; broker polls here |
| **Code repo** (your project) | Holds the code you want to benchmark |

In the code repo, a workflow — often on a `schedule` cron trigger — creates issues **in the queue repo** (via the GitHub API, authenticated with a GitHub App installation token). Each issue body is JSON with three fields: `commit`, `run_number`, and `param1`.

> **Note**: If you're creating issues from a workflow in a *different* repo, use the [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token) action to generate an installation token. This is cleaner than manually generating the JWT + exchanging it yourself — the action handles both steps and returns the token as an output you can pass to `gh` or `curl`.

> The pattern works either way: issues can be created in the same repo or a separate queue repo. A separate repo keeps your main project's issue tracker clean.

### 2. Broker (`gh2slurm`)

A Slurm job that:
- Polls the GitHub API for unclaimed issues matching its cluster label
- Claims issues by adding the `running` label
- Submits work to the cluster via `example_workflow.sh`
- Updates issue status on completion

Uses `--dependency=afterok` to chain poll jobs, creating a self-sustaining loop.

The broker relies on:
- `gh_setup` function: validates environment, generates a GitHub App JWT, exchanges it for an installation access token via the `gh-token` (or `gh-token-bash` fallback) CLI
- `GH_EXPORT_LIST`: a comma-separated list of env vars that gets forwarded to child Slurm jobs so they can generate their own tokens

### 3. Example Workflow (`example_workflow/example_workflow.sh`)

Submits a chain of three dependent Slurm jobs:

1. **`build_code.sh`** — compiles `helloworld.c` via Make
2. **`benchmark_code.sh`** — runs the binary with `time`, saves output to `timings.txt` (depends on build via `afterok`)
3. **`publish_results.sh`** — gathers job states via `sacct`, posts timing/results back to the issue, and either closes the issue or marks it `failed` (depends on both via `afterany`)

### 4. Supporting files

- `install-gh-cli_linux_amd64` / `install-gh-token_linux_amd64` — installers for the `gh` and `gh-token` CLIs into `./bin`
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
     │  submits one "manager" job
     ▼
example_workflow.sh — manager
     │
     │  sets up run dir, downloads code,
     │  submits 3 dependent Slurm jobs:
     ▼
  build_code.sh ──afterok──► benchmark_code.sh ──afterany──► publish_results.sh
     │                            │                               │
     ▼                            ▼                               ▼
  [slurm job]                 [slurm job]                posts timing to the issue,
                                                         closes or marks failed

```

Key points:
- The **broker** (`gh2slurm`) is short-lived — it only claims an issue and submits the manager, then exits. It doesn't do any actual work.
- The broker **resubmits itself FIRST** via `--dependency=afterok` — so the next poll is queued immediately, before the manager job even starts. This ensures the queue keeps moving even if the manager or work jobs fail.
- The **manager** (`example_workflow.sh`) runs in its own Slurm job and handles:
  - Setting up the run directory
  - Downloading the code at the commit hash from the issue
  - Submitting the 3 dependent work jobs
- The three **work jobs** all run inside Slurm, so they inherit cluster access (filesystem, modules, etc.).
- Only `publish_results.sh` talks back to GitHub — it comments timing on the issue and either closes it or adds a `failed` label.
- If any work job fails, `publish_results.sh` still runs (because of `afterany`) and reports the failure instead of silently succeeding.
