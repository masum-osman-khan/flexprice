# FlexPrice Event Processing Debug Summary

## Overview
This document provides a comprehensive summary of debugging the FlexPrice event processing pipeline when events accepted by the API were not showing up in the events list API.

## Timeline of Investigation

### Phase 1: Infrastructure Verification
1. **Container Status Check** - Verified all Docker containers were running
2. **Kafka Message Flow** - Confirmed events were being published to Kafka topics
3. **Topic Discovery** - Identified missing Kafka topics required for processing

### Phase 2: Missing Kafka Topics (Issue #1)
- **Problem**: Four critical Kafka topics were missing
- **Impact**: Consumer circuit breaker activated, stopping event processing
- **Solution**: Created missing topics and restarted consumer
- **Status**: ✅ Resolved
- **Details**: See `ISSUE-1-KAFKA-TOPICS-MISSING.md`

### Phase 3: API Configuration
- **Problem**: Missing API key in configuration
- **Impact**: API requests failing with authentication errors
- **Solution**: Added correct API key to `config.yaml`
- **Status**: ✅ Resolved

### Phase 4: Data Verification
- **Method**: Direct ClickHouse queries
- **Result**: Events were successfully stored in database
- **Finding**: Events existed but API returned empty results

### Phase 5: Environment ID Mismatch (Issue #2)
- **Problem**: Frontend localStorage contained stale environment ID
- **Impact**: API queried wrong environment, returning no results
- **Root Cause**: Browser cache inconsistency with backend data
- **Status**: ✅ Diagnosed, workaround provided
- **Details**: See `ISSUE-2-ENVIRONMENT-ID-MISMATCH.md`

## Key Findings

### 1. Event Processing Pipeline is Working
- Events are correctly ingested via API
- Kafka message publishing works
- Consumer processes messages successfully
- Data is stored in ClickHouse correctly

### 2. Frontend-Backend Synchronization Issues
- Browser localStorage can become stale
- Environment IDs need periodic validation
- No automatic recovery from environment mismatches

### 3. Infrastructure Dependencies
- Multiple Kafka topics are critical for operation
- Missing topics cause circuit breaker activation
- Consumer restart required after topic creation

## Technical Architecture Insights

### Event Flow
```
API POST /events → Kafka Topic → Consumer → ClickHouse → API GET /events/list → Frontend
```

### Critical Kafka Topics
- `events` (primary event ingestion)
- `events_post_processing` (post-processing pipeline)
- `events_post_processing_backfill` (backfill operations)
- `feature_tracking_service_backfill` (feature tracking)
- `system_events` (system-level events)

### Data Storage
- **Primary**: ClickHouse `events` table
- **Key Fields**: `environment_id`, `event_type`, `timestamp`, etc.
- **Indexing**: Partitioned by environment and date

## Tools and Commands Used

### Docker Management
```bash
docker compose ps                                    # Check container status
docker compose logs flexprice-consumer             # Check consumer logs
docker compose restart flexprice-consumer          # Restart consumer
```

### Kafka Operations
```bash
# List topics
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --list

# Create topic
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --create --topic TOPIC_NAME --partitions 3 --replication-factor 1

# Monitor messages
docker compose exec kafka kafka-console-consumer --bootstrap-server localhost:9092 --topic events --from-beginning
```

### ClickHouse Queries
```sql
-- Check event counts by environment
SELECT environment_id, COUNT(*) as event_count FROM events GROUP BY environment_id;

-- View recent events
SELECT * FROM events ORDER BY timestamp DESC LIMIT 10;
```

### API Testing
```bash
# Test event creation
curl -X POST "http://localhost:8080/api/v1/events" \
  -H "Content-Type: application/json" \
  -H "x-api-key: sk_01K5ZPDJXFH4CCZXF2QEQBY2AK" \
  -d '{"environment_id": "env_01K5ZPD3WGG2DKDXBZ2VDB0DSG", "event_type": "test", "properties": {}}'

# Test event retrieval
curl -X POST "http://localhost:8080/api/v1/events/list" \
  -H "Content-Type: application/json" \
  -H "x-api-key: sk_01K5ZPDJXFH4CCZXF2QEQBY2AK" \
  -d '{"environment_id": "env_01K5ZPD3WGG2DKDXBZ2VDB0DSG", "limit": 10}'
```

## Configuration Changes Made

### `/internal/config/config.yaml`
```yaml
api_key:
  keys:
    - "sk_01K5ZPDJXFH4CCZXF2QEQBY2AK"  # Added for API authentication
```

## Monitoring and Health Checks

### Key Metrics to Monitor
1. **Consumer Lag**: Kafka consumer group lag
2. **Circuit Breaker Status**: Consumer health
3. **Topic Availability**: All required topics exist
4. **API Response Times**: Event retrieval performance
5. **Environment Sync**: Frontend/backend environment consistency

### Health Check Commands
```bash
# Consumer group status
docker compose exec kafka kafka-consumer-groups --bootstrap-server localhost:9092 --describe --group flexprice-consumer-group

# Topic partition status
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --describe --topic events

# ClickHouse connection test
docker compose exec clickhouse clickhouse-client --query "SELECT 1"
```

## Future Prevention Measures

### 1. Infrastructure Monitoring
- [ ] Add Kafka topic existence checks to startup
- [ ] Implement consumer health monitoring
- [ ] Create alerts for missing topics

### 2. Frontend Resilience
- [ ] Add environment ID validation
- [ ] Implement localStorage refresh mechanism
- [ ] Create environment mismatch recovery

### 3. Development Workflow
- [ ] Add topic creation to setup scripts
- [ ] Include environment sync in testing checklist
- [ ] Document environment management process

### 4. Operational Procedures
- [ ] Regular Kafka topic audits
- [ ] Environment consistency checks
- [ ] Consumer lag monitoring

## Lessons Learned

1. **Infrastructure Dependencies**: All Kafka topics must exist before starting consumers
2. **Frontend State Management**: Browser localStorage needs validation and refresh mechanisms
3. **Environment Consistency**: Critical to maintain sync between frontend and backend
4. **Circuit Breaker Patterns**: Failed consumers need explicit restart after fixing root cause
5. **Multi-Layer Debugging**: Issues can occur at API, message queue, storage, and frontend layers

## Related Documentation
- `ISSUE-1-KAFKA-TOPICS-MISSING.md` - Detailed Kafka topic issue
- `ISSUE-2-ENVIRONMENT-ID-MISMATCH.md` - Detailed environment ID issue
- `README.md` - Project setup and running instructions
- `SETUP.md` - Development environment setup

## Contact Information
For questions about this debugging session or similar issues, refer to the individual issue files or the project documentation.
