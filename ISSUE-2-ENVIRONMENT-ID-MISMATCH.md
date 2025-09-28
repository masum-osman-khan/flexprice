# Issue #2: Environment ID Mismatch Due to Stale Frontend localStorage

## Problem Summary
Events are successfully processed and stored in ClickHouse but don't appear in the frontend events list due to environment ID mismatch between the stored events and the frontend's localStorage.

## Root Cause
The `flexprice-front` application stores environment configuration in browser localStorage, and when this data becomes stale or mismatched with the backend data, the frontend queries events using the wrong environment ID.

## Technical Details

### Environment ID Discrepancy
- **Events stored under**: `env_01K5ZPD3WGG2DKDXBZ2VDB0DSG`
- **Frontend querying with**: `env_01K5ZPD3WEA9MFTW1S2HS958EJ`

### Impact
- Events are correctly ingested and processed by the backend
- ClickHouse contains the events data
- API endpoints work correctly when called with the right environment ID
- Frontend appears empty because it's querying the wrong environment

## Evidence

### 1. Events Exist in ClickHouse
```sql
-- Query showing events are stored under env_01K5ZPD3WGG2DKDXBZ2VDB0DSG
SELECT environment_id, COUNT(*) as event_count 
FROM events 
GROUP BY environment_id;

-- Result:
-- env_01K5ZPD3WGG2DKDXBZ2VDB0DSG    5
```

### 2. API Works with Correct Environment ID
```bash
# Successful API call with correct environment ID
curl -X POST "http://localhost:8080/api/v1/events/list" \
  -H "Content-Type: application/json" \
  -H "x-api-key: sk_01K5ZPDJXFH4CCZXF2QEQBY2AK" \
  -d '{
    "environment_id": "env_01K5ZPD3WGG2DKDXBZ2VDB0DSG",
    "limit": 10
  }'

# Returns events successfully
```

### 3. API Returns Empty with Wrong Environment ID
```bash
# API call with wrong environment ID (from frontend localStorage)
curl -X POST "http://localhost:8080/api/v1/events/list" \
  -H "Content-Type: application/json" \
  -H "x-api-key: sk_01K5ZPDJXFH4CCZXF2QEQBY2AK" \
  -d '{
    "environment_id": "env_01K5ZPD3WEA9MFTW1S2HS958EJ",
    "limit": 10
  }'

# Returns empty results: {"events": [], "total_count": 0}
```

## localStorage Investigation

### Browser Developer Tools Check
1. Open `flexprice-front` in browser
2. Open Developer Tools (F12)
3. Go to Application/Storage tab → Local Storage
4. Look for keys containing environment configuration
5. Verify the environment ID matches the one used by backend

### Common localStorage Keys to Check
- `currentEnvironment`
- `selectedEnvironment`
- `environmentId`
- `env_config`
- Any keys containing environment or tenant information

## Solutions

### Immediate Fix
1. **Clear Browser localStorage**:
   ```javascript
   // In browser console
   localStorage.clear();
   // Or selectively clear environment-related keys
   Object.keys(localStorage).forEach(key => {
     if (key.includes('environment') || key.includes('env')) {
       localStorage.removeItem(key);
     }
   });
   ```

2. **Refresh/Re-login to Frontend**:
   - Log out of flexprice-front
   - Clear browser cache and localStorage
   - Log back in to fetch fresh environment configuration

### Long-term Prevention

#### 1. Environment Sync Validation
Add environment ID validation in the frontend:
```javascript
// Check if stored environment ID exists in backend
async function validateEnvironmentId(envId) {
  try {
    const response = await fetch('/api/v1/environments/' + envId, {
      headers: { 'x-api-key': apiKey }
    });
    return response.ok;
  } catch (error) {
    console.warn('Environment validation failed:', error);
    return false;
  }
}

// Clear localStorage if environment is invalid
if (!(await validateEnvironmentId(storedEnvId))) {
  localStorage.removeItem('currentEnvironment');
  // Redirect to environment selection or re-fetch from backend
}
```

#### 2. Automatic localStorage Refresh
Implement periodic refresh of environment configuration:
```javascript
// Refresh environment data every hour or on app start
const ENVIRONMENT_CACHE_TTL = 60 * 60 * 1000; // 1 hour

function refreshEnvironmentIfStale() {
  const lastRefresh = localStorage.getItem('env_last_refresh');
  const now = Date.now();
  
  if (!lastRefresh || (now - parseInt(lastRefresh)) > ENVIRONMENT_CACHE_TTL) {
    fetchFreshEnvironmentData();
    localStorage.setItem('env_last_refresh', now.toString());
  }
}
```

#### 3. Environment ID Mismatch Detection
Add API-level validation to detect mismatches:
```javascript
// In API response handler
if (response.status === 404 && requestContainsEnvironmentId) {
  // Possible environment ID mismatch
  console.warn('Possible environment ID mismatch detected');
  showEnvironmentMismatchWarning();
  // Optionally clear localStorage and re-authenticate
}
```

#### 4. Backend Environment Validation
Add middleware to validate environment IDs:
```go
// In Go backend
func ValidateEnvironmentMiddleware(next http.HandlerFunc) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        envID := extractEnvironmentID(r)
        if envID != "" {
            exists, err := environmentExists(envID)
            if err != nil || !exists {
                http.Error(w, "Invalid environment ID", http.StatusBadRequest)
                return
            }
        }
        next(w, r)
    }
}
```

## Prevention Checklist

- [ ] Implement environment ID validation in frontend
- [ ] Add periodic localStorage refresh mechanism
- [ ] Create environment mismatch detection and recovery
- [ ] Add backend validation for environment IDs
- [ ] Document environment setup process for developers
- [ ] Add logging for environment ID mismatches
- [ ] Create user-friendly error messages for environment issues

## Related Files
- `flexprice-front/src/` (frontend localStorage management)
- `/internal/config/config.yaml` (API key configuration)
- `docker-compose.yml` (environment setup)
- ClickHouse `events` table (data storage)

## Testing Steps
1. Create events with one environment ID
2. Manually set different environment ID in frontend localStorage
3. Verify events don't appear in frontend
4. Clear localStorage and re-authenticate
5. Verify events now appear correctly

## Severity
**Medium-High** - Affects user experience significantly but doesn't break core functionality. Events are processed correctly but invisible to users.

## Status
- [x] Root cause identified
- [x] Workaround documented
- [ ] Long-term solution implemented
- [ ] Prevention measures added
- [ ] Testing completed
