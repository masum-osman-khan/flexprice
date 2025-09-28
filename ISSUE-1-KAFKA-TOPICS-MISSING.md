# Issue #1: Events Not Processing - Missing Kafka Topics

## Problem Description
Events were being accepted by the API and published to Kafka successfully, but were not appearing in the events list API. The events were stuck in the processing pipeline due to missing Kafka topics required for post-processing.

## Root Cause
The FlexPrice event processing pipeline has multiple stages:
1. API receives event → Publishes to Kafka `events` topic
2. Primary consumer processes from `events` → Stores in ClickHouse + Publishes to `events_post_processing`
3. Post-processing consumer processes from `events_post_processing` → Handles business logic
4. Feature tracking consumer processes from `events` → Tracks feature usage

The issue was that the post-processing topics were missing, causing a **circuit breaker** to open and prevent message processing.

## Symptoms
- ✅ Events accepted by API: `{"event_id": "...", "message": "Event accepted for processing"}`
- ✅ Events visible in Kafka `events` topic
- ❌ Events not appearing in `/v1/events` API
- ❌ Consumer logs showing circuit breaker errors

## Error Messages in Logs
```
Failed to publish event to post-processing service: cannot produce message [...]: circuit breaker is open
```

## Missing Kafka Topics
The following topics were missing and needed to be created:

```bash
# Primary post-processing topic
events_post_processing

# Backfill topics for reprocessing
events_post_processing_backfill
feature_tracking_service_backfill

# System events for webhooks
system_events
```

## Solution
### Step 1: Create Missing Kafka Topics
```bash
# Create events post-processing topic
docker compose exec kafka kafka-topics --create --if-not-exists \
  --bootstrap-server kafka:9092 \
  --topic events_post_processing \
  --partitions 1 \
  --replication-factor 1

# Create backfill topics
docker compose exec kafka kafka-topics --create --if-not-exists \
  --bootstrap-server kafka:9092 \
  --topic events_post_processing_backfill \
  --partitions 1 \
  --replication-factor 1

docker compose exec kafka kafka-topics --create --if-not-exists \
  --bootstrap-server kafka:9092 \
  --topic feature_tracking_service_backfill \
  --partitions 1 \
  --replication-factor 1

# Create system events topic for webhooks
docker compose exec kafka kafka-topics --create --if-not-exists \
  --bootstrap-server kafka:9092 \
  --topic system_events \
  --partitions 1 \
  --replication-factor 1
```

### Step 2: Restart Consumer to Clear Circuit Breaker
```bash
docker compose restart flexprice-consumer
```

### Step 3: Verify Topics Created
```bash
docker compose exec kafka kafka-topics --bootstrap-server kafka:9092 --list
```

## Prevention
To prevent this issue in the future, update the `init-kafka` target in `Makefile` to create all required topics:

```makefile
init-kafka:
	@echo "Creating Kafka topics..."
	@for i in 1 2 3 4 5; do \
		echo "Attempt $$i: Checking if Kafka is ready..."; \
		if docker compose exec -T kafka kafka-topics --bootstrap-server kafka:9092 --list >/dev/null 2>&1; then \
			echo "Kafka is ready!"; \
			# Primary events topic
			docker compose exec -T kafka kafka-topics --create --if-not-exists \
				--bootstrap-server kafka:9092 \
				--topic events \
				--partitions 1 \
				--replication-factor 1; \
			# Post-processing topics
			docker compose exec -T kafka kafka-topics --create --if-not-exists \
				--bootstrap-server kafka:9092 \
				--topic events_post_processing \
				--partitions 1 \
				--replication-factor 1; \
			docker compose exec -T kafka kafka-topics --create --if-not-exists \
				--bootstrap-server kafka:9092 \
				--topic events_post_processing_backfill \
				--partitions 1 \
				--replication-factor 1; \
			docker compose exec -T kafka kafka-topics --create --if-not-exists \
				--bootstrap-server kafka:9092 \
				--topic feature_tracking_service_backfill \
				--partitions 1 \
				--replication-factor 1; \
			docker compose exec -T kafka kafka-topics --create --if-not-exists \
				--bootstrap-server kafka:9092 \
				--topic system_events \
				--partitions 1 \
				--replication-factor 1; \
			echo "All Kafka topics created successfully"; \
			exit 0; \
		fi; \
		echo "Kafka not ready yet, waiting..."; \
		sleep 5; \
	done
```

## Verification
After fixing, verify the pipeline works end-to-end:

### 1. Create an Event
```bash
curl --location --request POST 'localhost:8080/v1/events' \
--header 'x-api-key: sk_01K5ZPDJXFH4CCZXF2QEQBY2AK' \
--header 'Content-Type: application/json' \
--data-raw '{
  "event_name": "test.event",
  "external_customer_id": "test-customer",
  "properties": {
    "test": "value"
  },
  "source": "api"
}'
```

### 2. Verify Event in ClickHouse
```bash
docker compose exec clickhouse clickhouse-client --user=flexprice --password=flexprice123 \
  --database=flexprice --query \
  "SELECT id, event_name, external_customer_id FROM events WHERE external_customer_id = 'test-customer'"
```

### 3. Verify Event via API
```bash
curl 'http://localhost:8080/v1/events?external_customer_id=test-customer' \
-H 'x-api-key: sk_01K5ZPDJXFH4CCZXF2QEQBY2AK'
```

## Configuration Referenced
The topics are configured in `internal/config/config.yaml`:

```yaml
event_post_processing:
  topic: "events_post_processing"
  topic_backfill: "events_post_processing_backfill"

feature_usage_tracking:
  topic: "events"
  topic_backfill: "feature_tracking_service_backfill"

webhook:
  topic: "system_events"
```

## Related Files
- `cmd/server/main.go` - Consumer startup logic
- `internal/service/event_post_processing.go` - Post-processing service
- `internal/service/feature_usage_tracking.go` - Feature tracking service
- `docker-compose.yml` - Container orchestration
- `Makefile` - Topic initialization

## Impact
- **Before Fix**: Events accepted but not stored/retrievable
- **After Fix**: Complete end-to-end event processing pipeline working
- **Processing Time**: Events now processed within ~50-250ms

This issue affected the core event ingestion functionality and prevented proper event analytics and billing calculations.
