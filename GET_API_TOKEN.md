# Getting Proxmox API Token

EBS needs an API token to authenticate with your Proxmox VE server. This is more secure than username/password.

## Step 1: SSH into Proxmox (or use web UI)

### Via Web UI (Easiest)
1. Go to `https://virt-2.admin.siliconiq.com:8006`
2. Login as `root@pam` or your admin user
3. Left sidebar → **Datacenter** → **API Tokens**
4. Click **Add Token**

### Via SSH
```bash
ssh root@virt-2.admin.siliconiq.com
# Then use pveum CLI commands
```

## Step 2: Create Token

In the web UI, fill out:
- **User**: `root@pam` (or your user)
- **Token ID**: `ebs-backup` (any name you like)
- **Expire**: Set to a far future date or leave empty (never expires)
- **Privileges**: Leave as `Privileges=0` for now (we'll restrict later)

Click **Add**

## Step 3: Copy the Secret

You'll see a popup showing:
```
root@pam!ebs-backup:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**This is your TOKEN SECRET** — copy it somewhere safe (only shown once!)

## Step 4: Verify in Proxmox

From SSH or web UI, verify the token exists:
```bash
pveum user token list
# Should show:
# root@pam!ebs-backup
```

## What to Give Me

Send me (can be in IEx comment or chat):
```
PVE_HOST="virt-2.admin.siliconiq.com"
PVE_PORT=8006
PVE_USER="root@pam"
PVE_TOKEN_ID="ebs-backup"
PVE_TOKEN_SECRET="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

Or just paste the token string: `root@pam!ebs-backup:secret-here`

## Why API Tokens Are Better

- **Limited scope** — can restrict to specific nodes/VMs
- **Revokable** — can disable without changing password
- **Auditable** — logs show which token was used
- **No password exposure** — token isn't your actual password

---

**Once you have the token, I'll wire up the PVE client and we'll query your VMs.**
