# Fix Superset Deployment - SECRET_KEY Decryption Error

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the "Invalid decryption key" error that prevents superset-init container from completing by cleaning up all old encrypted data and fixing volume naming ambiguity.

**Architecture:**
- Docker Compose uses directory name as project name prefix for volumes
- Multiple volume prefixes exist (`azuredevops_*` and `s_*`) due to different invocation contexts
- Need to remove ALL old volumes and add explicit project naming to prevent ambiguity

**Tech Stack:**
- Docker Compose, Azure DevOps pipeline, PostgreSQL volumes, Apache Superset

---

## Problem Analysis

### Root Cause
Docker Compose automatically prefixes volume names with the **project name** (default: directory name). The deployment directory is `/home/vorne/azagent/_work/13/s`, so:

- Expected: `azuredevops_db_home` (if using `-f .azuredevops/docker-compose-deploy.yml`)
- Actual: `s_db_home` (defaulting to directory name `s`)

The user removed `azuredevops_db_home`, but the container is actually mounting `s_db_home`, so old encrypted data persists.

### Evidence
- Admin user "already exists" → database is NOT empty
- Same decryption error persists → old encrypted data still present
- Two sets of volumes visible:
  ```
  azuredevops_db_home
  azuredevops_superset_home
  s_db_home
  s_superset_home
  ```

---

## Task 1: Diagnose - Verify Actual Mounted Volume

**Files:**
- None (diagnostic step on blue-dev server)

**Step 1: SSH into blue-dev and inspect the container**

Run on blue-dev:
```bash
docker inspect superset_db --format '{{json .Mounts}}' | jq -r '.[] | select(.Name != null) | "\(.Name): \(.Source)"'
```

Expected output: Shows actual volume being mounted (likely `s_db_home`)

**Step 2: Verify database has data**

Run on blue-dev:
```bash
docker exec superset_db psql -U superset -d superset -c "SELECT COUNT(*) FROM ab_user WHERE username='admin';"
```

Expected: Returns `1` (admin user exists, confirming database has old data)

**Step 3: Document findings**

Create a note with the verified volume name for reference in Task 2.

---

## Task 2: Cleanup - Remove ALL Superset Volumes

**Files:**
- None (cleanup step on blue-dev server)

**Step 1: Stop and remove containers with volumes**

Run on blue-dev from the working directory:
```bash
cd /home/vorne/azagent/_work/13/s
docker compose -f .azuredevops/docker-compose-deploy.yml down -v
```

Expected: Containers stopped and removed, volumes removed

**Step 2: Manually remove any remaining volumes**

Run on blue-dev:
```bash
docker volume rm azuredevops_db_home azuredevops_superset_home s_db_home s_superset_home 2>/dev/null || echo "Some volumes already removed"
```

Expected: All volumes removed, errors ignored if already gone

**Step 3: Verify volumes are gone**

Run on blue-dev:
```bash
docker volume ls | grep -E 'superset|db_home|azuredevops|s_db_home|s_superset'
```

Expected: No matching volumes (empty output)

**Step 4: Run on blue-dev - Force remove any orphaned volumes**

Run on blue-dev:
```bash
docker system prune -v --volumes
```

Expected: Removes any dangling/orphaned volumes

---

## Task 3: Fix docker-compose - Add Explicit Project Name

**Files:**
- Modify: `.azuredevops/superset-pipeline.yml`

**Step 1: Add COMPOSE_PROJECT_NAME environment variable**

Find the "Deploy Superset" step in `.azuredevops/superset-pipeline.yml` (around line 420) and modify the docker-compose commands.

Add `--project-name azuredevops` to ALL docker-compose commands.

Search for:
```yaml
- bash: |
    docker compose -f docker-compose-deploy.yml
```

Replace with:
```yaml
- bash: |
    docker compose -f docker-compose-deploy.yml --project-name azuredevops
```

Make sure to update ALL occurrences of `docker compose` in the Deploy Superset step:
1. The `docker compose up -d` command
2. Any other docker-compose commands (if present)

**Step 2: Validate the changes**

Run on local machine:
```bash
grep -n "docker compose" .azuredevops/superset-pipeline.yml
```

Expected: All docker-compose commands now include `--project-name azuredevops`

**Step 3: Commit**

```bash
git add .azuredevops/superset-pipeline.yml
git commit -m "fix(pipeline): add explicit COMPOSE_PROJECT_NAME to prevent volume ambiguity

- Add --project-name azuredevops to all docker-compose commands
- Prevents confusion between azuredevops_* and s_* volume prefixes
- Ensures consistent volume naming across deployments"
```

---

## Task 4: Update Pipeline - Add Volume Cleanup for Dev

**Files:**
- Modify: `.azuredevops/superset-pipeline.yml`

**Step 1: Add cleanup step before deployment**

Find the "Deploy Superset" job in `.azuredevops/superset-pipeline.yml` and add a new step BEFORE the existing "Set Working Directory" step.

Add this new step:
```yaml
- bash: |
    echo "=== Cleaning up old volumes ==="
    cd "$(Pipeline.Workspace)/s" || exit 1
    docker compose -f .azuredevops/docker-compose-deploy.yml --project-name azuredevops down -v 2>/dev/null || echo "No existing containers to stop"
    echo "✓ Cleanup completed"
  displayName: Cleanup Old Volumes
```

This should be added as the FIRST step in the deployment strategy, before "Set Working Directory".

**Step 2: Validate step order**

Check that the steps in the "Deploy Superset" job are in this order:
1. Cleanup Old Volumes (new step)
2. Set Working Directory
3. Create .env.deploy
4. Deploy Superset

**Step 3: Commit**

```bash
git add .azuredevops/superset-pipeline.yml
git commit -m "feat(pipeline): add automatic volume cleanup for dev deployments

- Add 'Cleanup Old Volumes' step before deployment
- Ensures fresh database on each deployment
- Prevents SECRET_KEY decryption errors from old encrypted data
- Uses --project-name flag for consistency"
```

---

## Task 5: Test - Verify Clean Deployment

**Files:**
- Test: Manual pipeline run verification

**Step 1: Push changes to remote**

```bash
git push origin fix/pipeline-setup
```

**Step 2: Trigger pipeline in Azure DevOps**

Navigate to the pipeline in Azure DevOps web UI and run it manually with the latest commit.

**Step 3: Monitor pipeline logs**

Watch for the "Cleanup Old Volumes" step in the logs, verify it outputs "✓ Cleanup completed"

**Step 4: Monitor superset-init container logs**

After deployment, run on blue-dev:
```bash
docker logs superset_init --tail 50
```

Expected output should show:
```
Init Step 1/3 [Starting] -- Applying DB migrations
...
Init Step 1/3 [Complete] -- Applying DB migrations
Init Step 2/3 [Starting] -- Setting up admin user ( admin / admin )
...
Init Step 2/3 [Complete] -- Setting up admin user
Init Step 3/3 [Starting] -- Setting up roles and perms
...
Init Step 3/3 [Complete] -- Setting up roles and perms
```

All three steps should complete successfully with `[Complete]` status.

**Step 5: Verify all containers are running**

Run on blue-dev:
```bash
docker ps | grep superset
```

Expected output:
```
superset_cache    redis:7      ...   Up 5 hours (healthy)
superset_db       postgres:17.4 ...   Up X minutes (healthy)
superset_init     .../superset ...   Exited (0)  [IMPORTANT: exit 0!]
superset_app      .../superset ...   Up X minutes
```

The `superset_init` container should show `Exited (0)` not `Exited (1)`.

**Step 6: Verify health check passes**

In Azure DevOps, the "Verify Health" job should pass.

**Step 7: Test Superset web interface**

Open browser to: `http://blue-dev:5760`

Expected: Superset login page loads successfully (may need to check if it redirects to login).

---

## Summary

**Changes Made:**
1. Added explicit `--project-name azuredevops` to all docker-compose commands
2. Added automatic volume cleanup step for dev deployments
3. Ensures consistent volume naming across deployments

**How This Fixes the Issue:**
- Volume cleanup ensures no old encrypted data persists between deployments
- Explicit project name prevents creation of ambiguous volume prefixes
- Each deployment on blue-dev starts with a completely fresh database
- No more "Invalid decryption key" errors

**Rollback Plan (if needed):**
If issues arise, revert commits:
```bash
git revert HEAD~2..HEAD
git push origin fix/pipeline-setup
```

**Success Criteria:**
- superset-init exits with code 0 (success)
- All 3 init steps complete successfully
- superset_app container starts and stays running
- Health check passes
- Superset web interface accessible at http://blue-dev:5760
