# Azure DevOps Pipeline Docker Compose Environment Variable Fix

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix docker-compose deployment in Azure DevOps pipeline where environment variables from .env.deploy file are not being read correctly

**Architecture:** The pipeline has multiple bash steps that create .env.deploy file and then run docker-compose. The issue is that in Azure DevOps deployment jobs, the working directory may differ from expected, causing docker-compose to not find the .env.deploy file. We need to add validation, debugging, and proper working directory handling.

**Tech Stack:** Azure DevOps Pipelines, Docker Compose, Bash, YAML

---

## Problem Analysis

**Current State:**
- Pipeline creates .env.deploy file with environment variables
- Debug step shows all variables are set correctly in shell
- Docker-compose fails with "SUPERSET_IMAGE variable is not set"
- Container logs show: `service "superset" has neither an image nor a build context specified`

**Root Cause:**
The .env.deploy file is being created in one step, but when docker-compose runs in the next step, it cannot find the file OR the file exists but docker-compose is running from a different working directory.

**Key Findings from Logs:**
1. Variables ARE set in the shell (confirmed by debug output)
2. "Create .env.deploy" step output is NOT in the logs - step may be failing silently
3. Docker-compose DOES run (containers start) but superset-init fails immediately
4. The error about SUPERSET_IMAGE not being set comes from docker-compose variable substitution

---

## Task 1: Add Comprehensive Debugging to .env.deploy Creation

**Files:**
- Modify: `.azuredevops/superset-pipeline.yml` (lines 313-368)

**Step 1: Add working directory debug output**

Find line 313 in `.azuredevops/superset-pipeline.yml` where the "Create .env.deploy" step begins. Replace the entire step with this enhanced version:

```yaml
              # -------------------------------------
              # Create docker-compose env file
              # -------------------------------------
              - bash: |
                  echo "=== DEBUG: .env.deploy Creation ==="
                  echo "Current working directory: $(pwd)"
                  echo "Pipeline.Workspace: $(Pipeline.Workspace)"
                  echo ""
                  echo "Files in current directory:"
                  ls -la
                  echo ""
                  echo "Creating .env.deploy file..."

                  # Generate SUPERSET_SECRET_KEY (Flask secret key for session encryption)
                  # Secret variables are not passed to bash, so we generate it directly
                  SUPERSET_SECRET_KEY=$(openssl rand -base64 48 | tr -d '=+/' | cut -c1-64)
                  echo "✓ Generated SUPERSET_SECRET_KEY (64 chars)"

                  # Read admin password from temp file (written by PowerShell step)
                  # Secret variables are not passed to bash, so we use a file
                  ADMIN_PASSWORD_FILE="$(Agent.TempDirectory)/superset-admin-password.txt"
                  if [ -f "$ADMIN_PASSWORD_FILE" ]; then
                    SUPERSET_ADMIN_PASSWORD=$(cat "$ADMIN_PASSWORD_FILE")
                    echo "✓ Read admin password from temp file"
                  else
                    echo "✗ ERROR: Admin password file not found: $ADMIN_PASSWORD_FILE"
                    exit 1
                  fi

                  # Create .env.deploy file
                  cat > .env.deploy << EOF
                  SUPERSET_IMAGE=${FULL_IMAGE_NAME}

                  SUPERSET_SECRET_KEY=${SUPERSET_SECRET_KEY}
                  SUPERSET_ADMIN_USER=${SUPERSET_ADMIN_USER}
                  SUPERSET_ADMIN_PASSWORD=${SUPERSET_ADMIN_PASSWORD}
                  SUPERSET_PORT=${SUPERSET_PORT}

                  REDIS_HOST=redis
                  REDIS_PORT=6379

                  DOCKER_NETWORK=${DOCKER_NETWORK}
                  DOCKER_INITDB_DIR=${DOCKER_INITDB_DIR}
                  EOF

                  echo "✓ Created .env.deploy file"
                  echo ""
                  echo ".env.deploy file location:"
                  ls -la .env.deploy
                  echo ""
                  echo "Environment variables (non-sensitive):"
                  echo "  SUPERSET_IMAGE: ${FULL_IMAGE_NAME}"
                  echo "  SUPERSET_PORT: ${SUPERSET_PORT}"
                  echo "  SUPERSET_ADMIN_USER: ${SUPERSET_ADMIN_USER}"
                  echo "  REDIS_HOST: redis"
                  echo "  REDIS_PORT: 6379"
                  echo "  DOCKER_NETWORK: ${DOCKER_NETWORK}"
                  echo "  DOCKER_INITDB_DIR: ${DOCKER_INITDB_DIR}"
                  echo ""
                  echo "Content of .env.deploy (with secrets masked):"
                  cat .env.deploy | sed 's/PASSWORD=.*/PASSWORD=***masked***/g' | sed 's/SECRET_KEY=.*/SECRET_KEY=***masked***/g'
                  echo ""
                  echo "=== END DEBUG ==="
                env:
                  FULL_IMAGE_NAME: $(FULL_IMAGE_NAME)
                  SUPERSET_ADMIN_USER: $(SUPERSET_ADMIN_USER)
                  SUPERSET_PORT: $(SUPERSET_PORT)
                  DOCKER_NETWORK: $(DOCKER_NETWORK)
                  DOCKER_INITDB_DIR: $(DOCKER_INITDB_DIR)
                displayName: Create .env.deploy
```

**Step 2: Verify the change**

Run: `cat .azuredevops/superset-pipeline.yml | grep -A 50 "Create .env.deploy"`
Expected: Should show the enhanced debug output with working directory and file listing

**Step 3: Commit the change**

```bash
git add .azuredevops/superset-pipeline.yml
git commit -m "fix(pipeline): add comprehensive debugging to .env.deploy creation step

- Add working directory debug output
- Add file listing to verify current directory
- Add .env.deploy file existence check with ls -la
- Mask sensitive content when displaying file contents"
```

---

## Task 2: Add Validation to Deploy Superset Step

**Files:**
- Modify: `.azuredevops/superset-pipeline.yml` (lines 372-390)

**Step 1: Add .env.deploy validation before docker-compose**

Find line 373 where "Deploy Superset" step begins. Replace the entire step with this enhanced version:

```yaml
              # -------------------------------------
              # Deploy Superset
              # -------------------------------------
              - bash: |
                  echo "=== DEBUG: Deploy Superset ==="
                  echo "Current working directory: $(pwd)"
                  echo "Pipeline.Workspace: $(Pipeline.Workspace)"
                  echo ""
                  echo "Checking for .env.deploy file..."
                  if [ -f ".env.deploy" ]; then
                    echo "✓ .env.deploy exists in current directory"
                    ls -la .env.deploy
                  else
                    echo "✗ ERROR: .env.deploy NOT found in current directory"
                    echo ""
                    echo "Searching for .env.deploy in workspace..."
                    find "$(Pipeline.Workspace)" -name ".env.deploy" -type f 2>/dev/null || echo "No .env.deploy file found anywhere"
                    exit 1
                  fi
                  echo ""

                  echo "Loading environment variables from .env.deploy..."
                  set -a  # Automatically export all variables
                  source .env.deploy
                  set +a
                  echo "✓ Sourced .env.deploy"
                  echo ""
                  echo "Checking shell environment:"
                  env | grep -E "SUPERSET|DATABASE|POSTGRES|REDIS|DOCKER_NETWORK" | sort
                  echo ""

                  echo "Deploying with docker-compose..."
                  docker compose -f docker-compose-deploy.yml --env-file .env.deploy up -d

                  echo ""
                  echo "✓ Deployment completed"
                  echo ""
                  echo "Running containers:"
                  docker compose -f docker-compose-deploy.yml ps
                  echo ""
                  echo "=== END DEBUG ==="
                displayName: Deploy Superset
```

**Step 2: Verify the change**

Run: `cat .azuredevops/superset-pipeline.yml | grep -A 35 "Deploy Superset"`
Expected: Should show the validation logic and error handling

**Step 3: Commit the change**

```bash
git add .azuredevops/superset-pipeline.yml
git commit -m "fix(pipeline): add .env.deploy validation to Deploy Superset step

- Add check for .env.deploy existence before sourcing
- Add search for .env.deploy if not found in current directory
- Add comprehensive environment variable debugging
- Exit with error if .env.deploy is not found"
```

---

## Task 3: Fix Working Directory Issue in Deployment Job

**Files:**
- Modify: `.azuredevops/superset-pipeline.yml` (line 131-140)

**Step 1: Add workingDirectory to deployment job**

Find line 131 where the deployment job begins. Add `workingDirectory` to the deployment job:

```yaml
  jobs:
    - deployment: DeploySuperset
      displayName: Deploy Superset to blue-dev
      environment:
        name: ${{ parameters.targetEnvironment }}
        resourceType: VirtualMachine
      workspace:
        clean: all
      strategy:
        runOnce:
          deploy:
            steps:
              - checkout: self
                submodules: true

              - bash: |
                  echo "Setting working directory to Pipeline.Workspace/s..."
                  cd "$(Pipeline.Workspace)/s" || { echo "Failed to cd to $(Pipeline.Workspace)/s"; exit 1; }
                  echo "✓ Changed directory to: $(pwd)"
                  echo "Contents of current directory:"
                  ls -la
                displayName: Set Working Directory
```

**Step 2: Verify the change**

Run: `cat .azuredevops/superset-pipeline.yml | grep -A 20 "deployment: DeploySuperset"`
Expected: Should show the new "Set Working Directory" step as the first step after checkout

**Step 3: Commit the change**

```bash
git add .azuredevops/superset-pipeline.yml
git commit -m "fix(pipeline): add explicit working directory step to deployment job

- Add cd to Pipeline.Workspace/s as first step after checkout
- Add workspace cleanup with clean: all
- Add directory listing to verify correct location
- Ensures all subsequent steps run from correct directory"
```

---

## Task 4: Update docker-compose-deploy.yml for Better Variable Handling

**Files:**
- Modify: `.azuredevops/docker-compose-deploy.yml`

**Step 1: Add default values to prevent blank substitutions**

Update the services section to use default values for critical variables. Replace lines 45-79 with:

```yaml
  superset-init:
    image: ${SUPERSET_IMAGE:?SUPERSET_IMAGE environment variable is not set or empty}
    container_name: superset_init
    command: ["/app/docker/docker-init.sh"]
    user: "root"
    networks:
      - superset-network
      - oeeintellisuite
    env_file:
      - .env.deploy
    environment:
      # Superset configuration
      SUPERSET_SECRET_KEY: ${SUPERSET_SECRET_KEY:?SUPERSET_SECRET_KEY environment variable is not set or empty}

      # Metadata database (internal PostgreSQL)
      DATABASE_DB: superset
      DATABASE_HOST: db
      DATABASE_PASSWORD: superset
      DATABASE_USER: superset
      DATABASE_PORT: 5432
      DATABASE_DIALECT: postgresql

      # Redis
      REDIS_HOST: redis
      REDIS_PORT: 6379
    depends_on:
      redis:
        condition: service_healthy
      db:
        condition: service_healthy
    volumes: *superset-volumes
    healthcheck:
      disable: true

  superset:
    image: ${SUPERSET_IMAGE:?SUPERSET_IMAGE environment variable is not set or empty}
    container_name: superset_app
    command: ["/app/docker/docker-bootstrap.sh", "app-gunicorn"]
    user: "root"
    restart: unless-stopped
    networks:
      - superset-network
      - oeeintellisuite
    ports:
      - "${SUPERSET_PORT:-5760}:5760"
    env_file:
      - .env.deploy
    environment:
      # Superset configuration
      SUPERSET_SECRET_KEY: ${SUPERSET_SECRET_KEY:?SUPERSET_SECRET_KEY environment variable is not set or empty}

      # Metadata database (internal PostgreSQL)
      DATABASE_DB: superset
      DATABASE_HOST: db
      DATABASE_PASSWORD: superset
      DATABASE_USER: superset
      DATABASE_PORT: 5432
      DATABASE_DIALECT: postgresql

      # Redis
      REDIS_HOST: redis
      REDIS_PORT: "6379"

    depends_on:
      superset-init:
        condition: service_completed_successfully
    volumes: *superset-volumes
```

**The `:?variable}` syntax makes docker-compose fail with a clear error message instead of silently defaulting to blank.**

**Step 2: Verify the change**

Run: `cat .azuredevops/docker-compose-deploy.yml | grep -A 10 "superset-init:"`
Expected: Should show the new error-only substitution syntax

**Step 3: Commit the change**

```bash
git add .azuredevops/docker-compose-deploy.yml
git commit -m "fix(docker-compose): add error-only substitution for critical variables

- Use \${VAR:?error} syntax for SUPERSET_IMAGE and SUPERSET_SECRET_KEY
- Provides clear error messages when variables are not set
- Prevents silent failures with blank variable substitutions"
```

---

## Task 5: Push and Test the Fix

**Step 1: Push all changes to remote**

```bash
git push origin fix/pipeline-docker-compose-env-fix
```

**Step 2: Trigger a new pipeline run**

Navigate to: https://dev.azure.com/oee-intellisuite/oee-intellisuite/_build

Or trigger via CLI:
```bash
az pipelines run --name superset-pipeline --branch fix/pipeline-docker-compose-env-fix
```

**Step 3: Monitor the pipeline logs**

Watch for these specific outputs:

1. **"Set Working Directory" step** should show:
   - ✓ Changed directory to: /home/vorne/azagent/_work/13/s
   - Contents showing .azuredevops directory

2. **"Create .env.deploy" step** should show:
   - ✓ Created .env.deploy file
   - .env.deploy file location with ls -la output
   - Content with masked secrets

3. **"Deploy Superset" step** should show:
   - ✓ .env.deploy exists in current directory
   - Environment variables listed
   - Docker-compose up succeeds

4. **"Verify Health" step** should show:
   - ✓ Superset is healthy and responding

**Expected Results:**
- All containers start successfully (postgres, redis, superset-init, superset)
- superset-init completes successfully (exit 0)
- Superset web server responds to health checks
- No "variable is not set" warnings

**Step 4: If it still fails**

Check the logs for the new debug output:
1. Working directory - verify it's `/home/vorne/azagent/_work/13/s`
2. .env.deploy location - verify it exists in the working directory
3. Environment variables - verify all are set after sourcing .env.deploy

If .env.deploy is not found, the error message will now show exactly where it searched.

**Step 5: Verify Superset is running**

After successful deployment, verify:
```bash
# Check containers
docker ps | grep superset

# Check health
curl http://localhost:5760/health

# Check logs
docker logs superset_app --tail=50
```

---

## Task 6: Update Documentation

**Files:**
- Create: `docs/plans/2026-01-20-pipeline-deployment-fix-summary.md`

**Step 1: Create fix summary document**

```bash
cat > docs/plans/2026-01-20-pipeline-deployment-fix-summary.md << 'EOF'
# Azure DevOps Pipeline Deployment Fix Summary

**Date:** 2026-01-20
**Issue:** Docker-compose environment variables not being read from .env.deploy file

## Root Cause

In Azure DevOps deployment jobs, the working directory can be different from the checkout directory. The .env.deploy file was being created in one directory, but docker-compose was running from a different directory.

## Solution

1. **Added explicit working directory step** - First step after checkout changes to `$(Pipeline.Workspace)/s`
2. **Added .env.deploy validation** - Check file exists before sourcing, fail with clear error if not found
3. **Added comprehensive debugging** - Output working directory, file listings, and environment variables at each step
4. **Added error-only variable substitution** - Use `${VAR:?error}` syntax in docker-compose for critical variables

## Changes Made

- `.azuredevops/superset-pipeline.yml`: Added working directory step, validation, and debugging
- `.azuredevops/docker-compose-deploy.yml`: Added error-only substitution for critical variables

## Testing

Run the pipeline and verify:
1. Working directory is set correctly
2. .env.deploy file is created in the correct location
3. Docker-compose reads the file successfully
4. All containers start and health check passes
EOF
```

**Step 2: Commit the documentation**

```bash
git add docs/plans/2026-01-20-pipeline-deployment-fix-summary.md
git commit -m "docs(pipeline): add deployment fix summary document"
```

---

## Testing Checklist

- [ ] Working directory step executes successfully
- [ ] .env.deploy file is created in correct location
- [ ] All environment variables are present in shell
- [ ] Docker-compose up succeeds without errors
- [ ] superset-init container completes successfully
- [ ] superset container starts and passes health check
- [ ] Superset web server responds on configured port
- [ ] No "variable is not set" warnings in logs

---

## Additional Notes

**Why This Approach:**

1. **Defensive Programming** - Validate assumptions at each step (file exists, variables are set)
2. **Clear Error Messages** - Fail fast with descriptive errors instead of silent failures
3. **Comprehensive Debugging** - Output all relevant state for troubleshooting
4. **Minimal Changes** - Only add validation and debugging, don't change core application logic

**Alternative Approaches Considered:**

1. **Using `--project-directory` flag** - Could specify working directory to docker-compose directly
   - Pro: More explicit
   - Con: Would require passing the directory path dynamically

2. **Using absolute paths for env file** - Could use full path to .env.deploy
   - Pro: Would work regardless of working directory
   - Con: Less portable, harder to maintain across environments

3. **Combining steps into one** - Could create .env.deploy and run docker-compose in same step
   - Pro: Guarantees same working directory
   - Con: Reduces modularity, harder to debug individual issues

**Related Documentation:**
- Docker Compose Variable Substitution: https://docs.docker.com/compose/environment-variables/
- Azure DevOps Deployment Jobs: https://learn.microsoft.com/en-us/azure/devops/pipelines/process/phases?view=azure-pipelines
- Docker Compose Error-Only Substitution: https://docs.docker.com/compose/environment-variables/set-environment-variables/#substitute-environment-variables-in-compose-files
