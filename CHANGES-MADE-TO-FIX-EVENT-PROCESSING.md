# Changes Made to Fix Event Processing Issues

## Overview
This document lists all the specific changes that were made to resolve the event processing issues where events were accepted by the API but not showing up in the events list.

## 1. Created Missing Kafka Topics

### Problem
The following Kafka topics were missing, causing the consumer circuit breaker to activate:

### Topics Created
```bash
# Create events_post_processing topic
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --create --topic events_post_processing --partitions 3 --replication-factor 1

# Create events_post_processing_backfill topic  
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --create --topic events_post_processing_backfill --partitions 3 --replication-factor 1

# Create feature_tracking_service_backfill topic
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --create --topic feature_tracking_service_backfill --partitions 3 --replication-factor 1

# Create system_events topic
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --create --topic system_events --partitions 3 --replication-factor 1
```

### Verification Command
```bash
# Verify all topics exist
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --list

# Expected output should include:
# events
# events_post_processing
# events_post_processing_backfill
# feature_tracking_service_backfill
# system_events
```

## 2. Updated Configuration File

### File: `/internal/config/config.yaml`

### Change: Added Working API Key
```yaml
# BEFORE - Only had the original dev key
api_key:
  header: "x-api-key"
  keys:
    "c3b3fa371183f0df159d659da0b42c5270c8d53c22e180df2286e059c75802ab":
      tenant_id: "00000000-0000-0000-0000-000000000000"
      user_id: "00000000-0000-0000-0000-000000000000"
      name: "Dev API Keys"
      is_active: true

# AFTER - Added the working API key
api_key:
  header: "x-api-key"
  keys:
    "c3b3fa371183f0df159d659da0b42c5270c8d53c22e180df2286e059c75802ab":
      tenant_id: "00000000-0000-0000-0000-000000000000"
      user_id: "00000000-0000-0000-0000-000000000000"
      name: "Dev API Keys"
      is_active: true
    "sk_01K5ZPDJXFH4CCZXF2QEQBY2AK":
      tenant_id: "00000000-0000-0000-0000-000000000000"
      user_id: "00000000-0000-0000-0000-000000000000"
      name: "Working API Key"
      is_active: true
```

## 3. Restarted Services

### Consumer Service Restart
```bash
# Restart the consumer to clear circuit breaker
docker compose restart flexprice-consumer
```

### Verification Commands
```bash
# Check consumer is running and processing
docker compose logs flexprice-consumer --tail=50

# Look for successful processing messages like:
# "Successfully processed event"
# "Consumer started successfully"
```

## 4. Environment ID Resolution

### Problem Identified
- Events were stored under: `env_01K5ZPD3WGG2DKDXBZ2VDB0DSG`  
- Frontend was querying: `env_01K5ZPD3WEA9MFTW1S2HS958EJ`

### Solution Applied
Clear browser localStorage in the frontend application:

```javascript
// Execute in browser console for flexprice-front
localStorage.clear();

// Or selectively clear environment-related keys
Object.keys(localStorage).forEach(key => {
  if (key.includes('environment') || key.includes('env')) {
    localStorage.removeItem(key);
  }
});
```

### Verification Steps
1. Clear localStorage in browser
2. Refresh/re-login to frontend
3. Verify events now appear in the frontend

## 5. Database Verification

### ClickHouse Query to Confirm Events
```sql
-- Check events exist and count by environment
SELECT environment_id, COUNT(*) as event_count 
FROM events 
GROUP BY environment_id;

-- View recent events to verify structure
SELECT * FROM events 
ORDER BY timestamp DESC 
LIMIT 10;
```

### Expected Results
```
env_01K5ZPD3WGG2DKDXBZ2VDB0DSG    5
```

## 6. API Testing Commands

### Test Event Creation
```bash
curl -X POST "http://localhost:8080/api/v1/events" \
  -H "Content-Type: application/json" \
  -H "x-api-key: sk_01K5ZPDJXFH4CCZXF2QEQBY2AK" \
  -d '{
    "environment_id": "env_01K5ZPD3WGG2DKDXBZ2VDB0DSG",
    "event_type": "test_event",
    "properties": {
      "test": "value"
    }
  }'
```

### Test Event Retrieval  
```bash
curl -X POST "http://localhost:8080/api/v1/events/list" \
  -H "Content-Type: application/json" \
  -H "x-api-key: sk_01K5ZPDJXFH4CCZXF2QEQBY2AK" \
  -d '{
    "environment_id": "env_01K5ZPD3WGG2DKDXBZ2VDB0DSG",
    "limit": 10
  }'
```

## 7. Monitoring Commands Added

### Check Kafka Consumer Group Status
```bash
docker compose exec kafka kafka-consumer-groups --bootstrap-server localhost:9092 --describe --group flexprice-consumer-local
```

### Monitor Kafka Messages
```bash
# Monitor events topic
docker compose exec kafka kafka-console-consumer --bootstrap-server localhost:9092 --topic events --from-beginning

# Monitor post-processing topic  
docker compose exec kafka kafka-console-consumer --bootstrap-server localhost:9092 --topic events_post_processing --from-beginning
```

### Check Container Health
```bash
# Check all services are running
docker compose ps

# Check specific service logs
docker compose logs flexprice-consumer
docker compose logs clickhouse
docker compose logs kafka
```

## Summary of Changes

### Infrastructure Changes
- ✅ Created 4 missing Kafka topics
- ✅ Restarted consumer service to clear circuit breaker

### Configuration Changes  
- ✅ Added working API key to `config.yaml`

### Frontend Fix
- ✅ Cleared stale localStorage environment data

### Verification Added
- ✅ Database queries to confirm event storage
- ✅ API tests to verify end-to-end functionality
- ✅ Monitoring commands for ongoing health checks

## Files Modified
1. `/internal/config/config.yaml` - Added API key configuration
2. Kafka topics (infrastructure) - Created missing topics
3. Browser localStorage (frontend) - Cleared stale environment data

## Commands for Future Setup

If you encounter similar issues, run these commands in order:

```bash
# 1. Check and create missing Kafka topics
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --list
# Create any missing topics from the list above

# 2. Restart consumer if circuit breaker is active
docker compose restart flexprice-consumer

# 3. Verify API key exists in config.yaml
# Add sk_01K5ZPDJXFH4CCZXF2QEQBY2AK if missing

# 4. Test API endpoints
# Use the curl commands above

# 5. Clear frontend localStorage if environment mismatch
# Use browser console commands above

# 6. Verify events in ClickHouse
docker compose exec clickhouse clickhouse-client --query "SELECT environment_id, COUNT(*) FROM events GROUP BY environment_id"
```

## Prevention for Future
- Add topic creation to setup scripts
- Implement environment ID validation in frontend  
- Add consumer health monitoring
- Document environment management process
