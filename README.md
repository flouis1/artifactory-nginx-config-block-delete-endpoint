# Artifactory DELETE Protection - Simple & Working

This solution adds **DELETE protection** to JFrog Artifactory using the official JFrog Helm chart with a simple configuration override.

## What This Does

- **Blocks DELETE operations** on API and web interface for unauthorized IPs
- **Uses official JFrog Helm chart** - no modifications needed
- **Simple single-file approach** - just one YAML file
- **Works out of the box** - tested and validated

## Files

```
helm-integration/
├── artifactory-with-security.yaml   # Main configuration file (only file needed!)
└── README.md                        # This documentation
```

## Quick Install

### 1. Prerequisites

```bash
# Add JFrog repository
helm repo add jfrog https://charts.jfrog.io
helm repo update
```

### 2. Customize Your IPs

Edit `artifactory-with-security.yaml` and update your authorized IPs in the `map $remote_addr $delete_allowed` section:

```yaml
# AUTHORIZED IPs - CUSTOMIZE HERE
172.16.1.99 1;    # Your IP #1
172.16.1.119 1;   # Your IP #2 (current)
# Add more IPs as needed:
# 192.168.1.100 1;  # Example admin IP
# 10.0.0.50 1;      # Another admin IP
```

### 3. Deploy

```bash
# Create namespace
kubectl create namespace artifactory

# Install Artifactory with DELETE protection
helm upgrade --install artifactory jfrog/artifactory \
  --namespace artifactory \
  -f artifactory-with-security.yaml \
  --wait --timeout 20m
```

**For upgrades (if PostgreSQL password is required):**
```bash
# Get existing PostgreSQL password
export PASSWORD=$(kubectl get secret --namespace "artifactory" artifactory-postgresql -o jsonpath="{.data.password}" | base64 -d)

# Upgrade with password and database readiness
helm upgrade --install artifactory jfrog/artifactory \
  --set databaseUpgradeReady=true \
  --set global.postgresql.auth.password=$PASSWORD \
  --namespace artifactory \
  -f artifactory-with-security.yaml \
  --wait --timeout 20m
```

### 4. Get Access URL

```bash
# Get LoadBalancer IP
kubectl get service artifactory-artifactory-nginx -n artifactory

# Or use port-forward for testing
kubectl port-forward svc/artifactory-artifactory-nginx 8080:80 -n artifactory
# Then access: http://localhost:8080
```

## Default Credentials

- **Username**: `admin`
- **Password**: `password`

**WARNING: Change the password immediately after first login!**

## Testing DELETE Protection

### Test Blocked DELETE (unauthorized IP)
```bash
# This should return 403 Forbidden with custom JSON message
curl -X DELETE "http://YOUR-ARTIFACTORY-URL/artifactory/api/repositories/test-repo"

# Expected response:
# {"error": "DELETE_OPERATION_BLOCKED", "status": 403, "message": "DELETE operations are restricted for security reasons.", "client_ip": "10.168.1.1", "timestamp": "2025-09-26T14:52:48+00:00"}
```

### Test Modern UI API Protection
```bash
# This should also return 403 Forbidden
curl -X DELETE "http://YOUR-ARTIFACTORY-URL/ui/api/v1/ui/admin/repositories/test-repo/delete"

# Expected response:
# {"error": "UI_API_DELETE_BLOCKED", "status": 403, "message": "DELETE operations through modern UI API are restricted.", "client_ip": "10.168.1.1", "timestamp": "2025-09-26T14:52:54+00:00"}
```

### Test Allowed DELETE (authorized IP)
```bash
# First create a test repo
curl -u admin:password -X PUT "http://YOUR-ARTIFACTORY-URL/artifactory/api/repositories/test-repo" \
  -H "Content-Type: application/json" \
  -d '{"key": "test-repo", "rclass": "local", "packageType": "generic"}'

# Then delete it (should work from authorized IP)
curl -u admin:password -X DELETE "http://YOUR-ARTIFACTORY-URL/artifactory/api/repositories/test-repo"
```

## How It Works

### The Magic
Our `artifactory-with-security.yaml` file uses the `nginx.artifactoryConf` parameter to **completely replace** the default nginx configuration with our security-enhanced version.

### What We Did
1. **Copied the original JFrog nginx config** from their GitHub repository
2. **Added our DELETE protection logic** at the top (IP maps and security rules)
3. **Embedded it directly in Helm values** so templates are processed correctly
4. **Added security location blocks** for API and UI protection

### Security Features
- **IP-based authorization**: Only specified IPs can perform DELETE operations
- **Multiple endpoint protection**: API, Modern UI API, and web interface
- **Custom error messages**: JSON responses with client IP and timestamp
- **Security logging**: Specialized logs for blocked DELETE attempts
- **Security headers**: Added to all responses for tracking

## Updating the Configuration

### To Add/Remove Authorized IPs
1. Edit `artifactory-with-security.yaml`
2. Update the `map $remote_addr $delete_allowed` section
3. Redeploy:
   ```bash
   helm upgrade artifactory jfrog/artifactory -f artifactory-with-security.yaml -n artifactory
   ```

### To Update to Latest JFrog Config
1. Download the latest config from JFrog's GitHub:
   ```bash
   curl -s "https://raw.githubusercontent.com/jfrog/charts/master/stable/artifactory/files/nginx-artifactory-conf.yaml" -o latest-jfrog.conf
   ```
2. Merge with our security additions (the DELETE protection maps and location blocks)
3. Update `artifactory-with-security.yaml`
4. Redeploy

## Security Details

### Protected Endpoints
- **`/artifactory/api/*`** - All Artifactory API DELETE operations
- **`/ui/api/v1/ui/admin/repositories/*/delete`** - Modern UI repository deletion
- **General protection** - All DELETE requests are logged and monitored

### IP Authorization Logic
```nginx
map $remote_addr $delete_allowed {
    default 0;  # Block all IPs by default
    172.16.1.99 1;    # Allow specific IPs
    172.16.1.119 1;   # Add more as needed
}
```

### Security Headers Added
- `X-Delete-Protection: enabled` - Indicates protection is active
- `X-UI-API-Protection: enabled` - For UI API endpoints
- Standard security headers preserved from original config


## Troubleshooting

### Common Issues

**Nginx pod crashing:**
- Check if IP addresses are correctly formatted in the config
- Ensure nginx syntax is valid (no missing semicolons, braces)

**DELETE still working for unauthorized IPs:**
- Verify your IP is not in the authorized list
- Check if you're testing from the correct external IP
- Confirm the configuration was applied: `helm get values artifactory -n artifactory`

**403 errors for authorized users:**
- Verify your IP is correctly added to the `$delete_allowed` map
- Check the format: `YOUR.IP.ADDRESS 1;`
- Redeploy after making changes

### Debugging Commands

```bash
# Check current configuration
helm get values artifactory -n artifactory

# Check nginx pod logs
kubectl logs deployment/artifactory-artifactory-nginx -n artifactory

# Check if config is applied
kubectl describe configmap artifactory-nginx-artifactory-conf -n artifactory

# Test nginx configuration syntax
kubectl exec deployment/artifactory-artifactory-nginx -n artifactory -- nginx -t

# Restart nginx if needed
kubectl rollout restart deployment/artifactory-artifactory-nginx -n artifactory
```

## Summary

This solution provides:

- **Simple Setup** - Single YAML file, works out of the box  
- **DELETE Protection** - Comprehensive security for all endpoints  
- **Upgrade Safety** - Uses official Helm chart parameters  
- **Production Ready** - Tested and documented  
- **Easy Maintenance** - Just edit IPs and redeploy  

**Your Artifactory is now secure with minimal complexity!**

---

*Based on the official JFrog Artifactory nginx configuration with added DELETE protection. Configuration is embedded directly in Helm values for maximum compatibility and reliability.*
