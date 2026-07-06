# GitHub Issues as a Slurm Job Queue

A pattern for using GitHub Issues as a persistent, human-readable job queue that triggers work on a Slurm cluster from GitHub Actions.

## Overview

This project implements a job queue where:
- GitHub Actions creates issues to represent work items
- A Slurm daemon polls the queue and processes items
- Results are tracked through issue labels and comments

## Key Design Decisions

- **Issues as queue items**: Human-readable, easy to inspect/debug
- **State tracking**: Labels: `unclaimed` and `failed`. Claimed issues have the label removed, and completed issues are closed.
- **Self-chaining polls**: Each poll job schedules the next via `--dependency=afterok`
- **No SSH credentials needed**: Polling via GitHub API avoids putting SSH keys on the cluster or managing SSH config — the daemon just needs API access
- **Effective cron replacement**: Many compute clusters don't have cron enabled; the poll loop gives you scheduled work without relying on cron
- **Separate queue repo**: Keeps main project issues clean (recommended)


## Components

### 1. Queue Workflow (`queue.yml`)

Creates a milestone and one issue per cluster when triggered. Each issue contains:
- Cluster name as a label
- Work parameters in the issue body
- Link to the workflow run

### 2. Poller Daemon (`gh-iqpd_template.sh`)

A Slurm job that:
- Polls GitHub API for unclaimed issues matching its cluster label
- Claims issues by updating labels
- Submits work to the cluster
- Updates issue status on completion

Uses `--dependency=afterok` to chain poll jobs, creating a self-sustaining loop.

### 3. Example Work (`example_work.sh`)

Demonstrates a simple Slurm job that:
- Reads parameters from an issue
- Performs work
- Updates the issue with results

## Architecture

```
GitHub Actions → Creates milestone + issues
                      ↓
Slurm Poller → Claims issues → Submits work → Updates issues
                      ↓
                 Next poll (via --dependency=afterok)
```

## GitHub App Setup

### 1. Create the App

Go to GitHub → Settings → Developer settings → GitHub Apps → **New GitHub App**

Fill in:
- **Name**: e.g. `slurm-queue-bot`
- **Homepage URL**: your queue repo URL (e.g. `https://github.com/myorg/slurm-queue`)
- **Webhooks**: disable (uncheck "Active")
- **Repository permissions**: Issues → Read & write
- **Where can it be installed**: Only on this account

Click **Create app**.

### 2. Get Credentials

After creating the app, you'll see:
- **App ID** — copy this
- Under **Private keys** → click **Generate a private key** — save the `.pem` file

### 3. Install the App

On the app settings page, click **Install App** → select your queue repo.

After installing, find the **Installation ID** from the URL:
```
https://github.com/settings/installations/INSTALLATION_ID
```

### 4. Configure Environment

Set these variables in your daemon script or environment:
- `GH_APP_ID` — your app ID
- `GH_APP_INSTALL_ID` — the installation ID
- `GH_APP_KEY` — path to the private key `.pem` file
- `GH_REPO` — owner/repo format (e.g. `myorg/slurm-queue`)

## Setup

### Prerequisites

Install CLI tools:
```bash
./install-gh-cli_linux_amd64
./install-gh-token_linux_amd64
```

### Deployment

1. Edit `gh-iqpd_template.sh` with your cluster name and queue label
2. Submit the poller: `sbatch gh-iqpd_template.sh`
3. Trigger work via GitHub Actions workflow

## Files

- `queue.yml` - GitHub Actions workflow
- `gh-iqpd_template.sh` - Poller daemon template
- `example_work.sh` - Sample work script
- `bin/` - CLI tools (gh, gh-token)
