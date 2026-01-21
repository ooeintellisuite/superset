# Azure DevOps SECRET_KEY Setup Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Set up SUPERSET_SECRET_KEY as a pipeline parameter to enable consistent deployments without database decryption errors.

**Architecture:** Azure DevOps pipeline parameters are used to pass SECRET_KEY to the deployment. The PowerShell step reads from `${{ parameters.SUPERSET_SECRET_KEY }}` (injected at runtime) and writes to a temp file for bash to read.

**⚠️ SECURITY NOTE:** Parameters are less secure than secret variables and may appear in pipeline logs. This is acceptable for the blue-dev environment but should NOT be used for production.

**Tech Stack:** Azure DevOps Pipelines, YAML, PowerShell, Bash

---

## Problem Context

**Current Issue:**
- Pipeline generates a random SECRET_KEY on each deployment
- Superset uses SECRET_KEY to encrypt sensitive data in metadata database
- New key = "Invalid decryption key" error = deployment failure
- Root cause: `superset_init` container exits with code 1

**Evidence from blue-dev server:**
```
superset_init   Exited (1) 22 hours ago
superset_app    Created (never started)
```

**Error in logs:**
```
ValueError: Invalid decryption key
```

**Solution:** Use a persistent SECRET_KEY passed as a pipeline parameter.

---

## Task 1: Generate a Strong SECRET_KEY

**Step 1: Generate the secret key locally**

Run this command to generate a cryptographically strong 64-character key:

```bash
openssl rand -base64 48 | tr -d '=+/' | cut -c1-64
```

Expected output: A 64-character string like:
```
aB3xK9mP2qL7vN4wR8sT6uY1cF5hG8jM2nP4qR7sT1uV5wX9zB3cK6mN9pQ2sT5uV
```

**Step 2: Save the key securely**

Copy the generated key to a secure location (password manager, encrypted file, etc.). You'll need it for Task 2.

**CRITICAL:** This key must be consistent across all deployments. Do NOT generate a new key for each deployment.

---

## Task 2: Use SECRET_KEY Parameter When Running Pipeline

**The SECRET_KEY is already configured as a pipeline parameter in the YAML (lines 17-20).**

**Step 1: Run pipeline with parameter**

When triggering the pipeline, you'll need to provide the SUPERSET_SECRET_KEY value:

**Via Azure DevOps UI:**
1. Go to **Pipelines** → **superset-pipeline**
2. Click **Run**
3. You'll see the **SUPERSET_SECRET_KEY** parameter listed
4. Paste the key from Task 1: `wevhI7GWgdQgO1kThaXroV9x2BTfj51aAeJxTuupoFx8mdRl2B8dHOXWX`
5. Click **Run**

**Via Azure CLI:**
```bash
az pipelines run \
  --name superset-pipeline \
  --branch fix/pipeline-setup \
  --parameters SUPERSET_SECRET_KEY="wevhI7GWgdQgO1kThaXroV9x2BTfj51aAeJxTuupoFx8mdRl2B8dHOXWX"
```

**⚠️ Security Note:** This value will be visible in pipeline run logs. For production environments, request admin access to set up a secret variable instead.

---

## Task 3: Push Changes and Run Pipeline

**Step 1: Push the code changes**

```bash
git push origin fix/pipeline-setup
```

**Step 2: Run pipeline with SECRET_KEY parameter**

Via Azure DevOps UI:
1. Go to **Pipelines** → **superset-pipeline**
2. Click **Run**
3. Select branch: `fix/pipeline-setup`
4. Fill in **SUPERSET_SECRET_KEY**: `wevhI7GWgdQgO1kThaXroV9x2BTfj51aAeJxTuupoFx8mdRl2B8dHOXWX`
5. Click **Run**

**Step 3: Monitor pipeline logs**

Watch for these success indicators:

**Create .env.deploy step:**
```
✓ SECRET_KEY written to temp file
✓ Created .env.deploy file
```

**Deploy Superset step:**
```
✓ Changed directory to: /home/vorne/azagent/_work/13/s
✓ .env.deploy exists in current directory
✓ Deployment completed
```

**Verify Health step:**
```
✓ Superset is healthy and responding
```

---

## Task 4: Clean Up Existing Deployment (If Needed)

**IMPORTANT:** Only needed if there's existing encrypted data from old key.

**Step 1: Check if cleanup is needed**

From previous investigation, blue-dev has:
```
superset_init   Exited (1)  ← Failed with old key
superset_app    Created (not running)
```

**Step 2: Reset database volumes**

If you don't need to preserve existing dashboards:

```bash
ssh -i 00-creds/blue-dev-ssh-key.pem vorne@10.10.21.2

# Stop and remove containers
docker compose -f .azuredevops/docker-compose-deploy.yml --project-name azuredevops down -v

# Remove volumes
docker volume rm azuredevops_db_home azuredevops_superset_home
```

---

## Task 5: Verify Deployment Success

**Step 1: After pipeline completes, verify containers**

SSH to blue-dev:
```bash
ssh -i 00-creds/blue-dev-ssh-key.pem vorne@10.10.21.2
docker ps | grep superset
```

Expected output:
```
superset_db     Up X minutes (healthy)
superset_cache  Up X minutes (healthy)
superset_init   Exited (0)  ← Success! Exit code 0
superset_app    Up X minutes  ← Running!
```

**Step 2: Verify Superset is responding**

```bash
curl http://localhost:5760/health
```

Expected: HTTP 200 response.

---

## Task 6: Document for Future Reference

**The SECRET_KEY to use for all future deployments:**

```
wevhI7GWgdQgO1kThaXroV9x2BTfj51aAeJxTuupoFx8mdRl2B8dHOXWX
```

**Save this key securely** - you'll need to provide it each time you run the pipeline.

**⚠️ IMPORTANT:**
- Use the SAME key for all deployments
- Never generate a new key without database reset
- This key is visible in pipeline logs (acceptable for blue-dev)
- For production, request admin to set up secret variable

---

---

## Testing Checklist

- [x] SECRET_KEY generated: `wevhI7GWgdQgO1kThaXroV9x2BTfj51aAeJxTuupoFx8mdRl2B8dHOXWX`
- [ ] Pipeline parameter configured (already in YAML lines 17-20)
- [ ] Code pushed to remote
- [ ] Pipeline run with SECRET_KEY parameter
- [ ] superset_init exits with code 0 (not 1)
- [ ] superset_app container is running
- [ ] Health check returns HTTP 200
- [ ] No "Invalid decryption key" errors

---

## Troubleshooting

**Issue: "Template expansion failed" or parameter error**

**Cause:** SUPERSET_SECRET_KEY parameter not provided when running pipeline.

**Fix:** When running pipeline, make sure to fill in the SUPERSET_SECRET_KEY parameter value with the generated key.

---

**Issue: "Invalid decryption key" error persists**

**Cause:** Old encrypted data in database with different key.

**Fix:** Reset database volumes (Task 4) before running pipeline again.

---

**Issue: superset_init still exits with code 1**

**Debug:**
```bash
# Check init logs
docker logs superset_init --tail=50
```

---

## Security Notes

**Why parameters (less secure but acceptable for blue-dev):**
- No access to Azure DevOps Variables UI (permissions)
- Parameter values visible in pipeline logs
- Acceptable for blue-dev environment
- NOT acceptable for production

**Production recommendation:**
- Request admin access to set up SECRET_KEY as secret variable
- Or use Azure Key Vault integration

---

## Related Files

- **Pipeline:** `.azuredevops/superset-pipeline.yml` (lines 17-20 for parameter, line 292 for usage)
- **Docker Compose:** `.azuredevops/docker-compose-deploy.yml`
- **Plan:** This document

---

## Success Criteria

Deployment is successful when:
1. ✅ Pipeline runs without errors
2. ✅ superset_init exits with code 0
3. ✅ superset_app container is running
4. ✅ Health check passes
5. ✅ No "Invalid decryption key" errors
6. ✅ Subsequent deployments work with same SECRET_KEY parameter value
