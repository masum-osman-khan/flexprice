#!/bin/bash
set -e

echo "🧪 Testing FlexPrice setup..."

API_KEY="sk_01K5ZPDJXFH4CCZXF2QEQBY2AK"
BASE_URL="http://localhost:8080"
TEST_ENV_ID="env_test_setup_$(date +%s)"

# Function to check if service is responding
check_service() {
    local url=$1
    local service_name=$2
    local max_attempts=30
    local attempt=1
    
    echo "Checking $service_name..."
    while [ $attempt -le $max_attempts ]; do
        if curl -s --max-time 5 "$url" >/dev/null 2>&1; then
            echo "✅ $service_name is responding"
            return 0
        fi
        echo "   Attempt $attempt/$max_attempts failed, retrying..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo "❌ $service_name failed to respond after $max_attempts attempts"
    return 1
}

# Test 1: Service availability
echo "1️⃣ Testing service availability..."
check_service "${BASE_URL}/health" "FlexPrice API"

# Test 2: Create a test event
echo "2️⃣ Creating test event..."
EVENT_RESPONSE=$(curl -s -w "%{http_code}" -X POST "${BASE_URL}/api/v1/events" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${API_KEY}" \
    -d "{
        \"environment_id\": \"${TEST_ENV_ID}\",
        \"event_type\": \"setup_test\",
        \"properties\": {
            \"test\": \"setup_verification\",
            \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
            \"setup_id\": \"$(uuidgen)\"
        }
    }")

# Extract HTTP status code (last 3 characters)
HTTP_STATUS="${EVENT_RESPONSE: -3}"
RESPONSE_BODY="${EVENT_RESPONSE%???}"

if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "201" ]; then
    echo "✅ Event created successfully (HTTP $HTTP_STATUS)"
elif [ "$HTTP_STATUS" = "000" ]; then
    echo "❌ Failed to connect to API. Is the service running?"
    echo "   Try: docker compose ps"
    exit 1
else
    echo "❌ Event creation failed (HTTP $HTTP_STATUS)"
    echo "   Response: $RESPONSE_BODY"
    echo "   Check API logs: docker compose logs flexprice-api"
    exit 1
fi

# Test 3: Wait for event processing
echo "3️⃣ Waiting for event processing..."
echo "   Checking consumer logs..."
CONSUMER_LOGS=$(docker compose logs --tail=10 flexprice-consumer 2>/dev/null || echo "No consumer logs available")
if echo "$CONSUMER_LOGS" | grep -q "error\|Error\|ERROR"; then
    echo "⚠️  Consumer errors detected:"
    echo "$CONSUMER_LOGS" | grep -i error | tail -3
fi

sleep 8

# Test 4: Retrieve events
echo "4️⃣ Retrieving events..."
EVENTS_RESPONSE=$(curl -s -w "%{http_code}" -X POST "${BASE_URL}/api/v1/events/list" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${API_KEY}" \
    -d "{
        \"environment_id\": \"${TEST_ENV_ID}\",
        \"limit\": 10
    }")

# Extract HTTP status and body
HTTP_STATUS="${EVENTS_RESPONSE: -3}"
RESPONSE_BODY="${EVENTS_RESPONSE%???}"

if [ "$HTTP_STATUS" != "200" ]; then
    echo "❌ Events retrieval failed (HTTP $HTTP_STATUS)"
    echo "   Response: $RESPONSE_BODY"
    exit 1
fi

# Check if events were found
if echo "$RESPONSE_BODY" | grep -q '"total_count":0\|"total_count": 0'; then
    echo "⚠️  Events not found yet. Possible causes:"
    echo "   - Events still being processed (normal for first run)"
    echo "   - Consumer circuit breaker (check logs: docker compose logs flexprice-consumer)"
    echo "   - Kafka topic issues (check: docker compose exec kafka kafka-topics --list --bootstrap-server localhost:9092)"
    echo ""
    echo "   Debugging commands:"
    echo "   - Check ClickHouse: docker compose exec clickhouse clickhouse-client --query \"SELECT COUNT(*) FROM events\""
    echo "   - Check Kafka messages: docker compose exec kafka kafka-console-consumer --bootstrap-server localhost:9092 --topic events --from-beginning --timeout-ms 5000"
    echo ""
    echo "   This might be normal for a fresh setup. Try running the test again in 30 seconds."
else
    TOTAL_COUNT=$(echo "$RESPONSE_BODY" | grep -o '"total_count":[0-9]*' | cut -d':' -f2)
    echo "✅ Events retrieved successfully (found $TOTAL_COUNT events)"
fi

# Test 5: Check Kafka topics
echo "5️⃣ Verifying Kafka topics..."
TOPICS=$(docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --list 2>/dev/null || echo "")
required_topics=("events" "events_post_processing" "events_post_processing_backfill" "feature_tracking_service_backfill" "system_events")

missing_topics=()
for topic in "${required_topics[@]}"; do
    if echo "$TOPICS" | grep -q "^${topic}$"; then
        echo "✅ Topic '$topic' exists"
    else
        echo "❌ Topic '$topic' missing"
        missing_topics+=("$topic")
    fi
done

if [ ${#missing_topics[@]} -gt 0 ]; then
    echo "⚠️  Missing topics detected. Creating them now..."
    for topic in "${missing_topics[@]}"; do
        docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --create --if-not-exists --topic "$topic" --partitions 3 --replication-factor 1
    done
    echo "✅ Missing topics created. Restart consumer: docker compose restart flexprice-consumer"
fi

# Test 6: Check services
echo "6️⃣ Checking service status..."
UNHEALTHY=$(docker compose ps --format json | jq -r '.[] | select(.State != "running") | .Name' 2>/dev/null || echo "")
if [ -n "$UNHEALTHY" ]; then
    echo "⚠️  Some services are not running:"
    echo "$UNHEALTHY"
    docker compose ps
else
    echo "✅ All services are running"
fi

# Test 7: Check ClickHouse connectivity
echo "7️⃣ Testing ClickHouse connectivity..."
CH_TEST=$(docker compose exec clickhouse clickhouse-client --query "SELECT 1" 2>/dev/null || echo "failed")
if [ "$CH_TEST" = "1" ]; then
    echo "✅ ClickHouse connection working"
    
    # Check if events table exists and has data
    EVENT_COUNT=$(docker compose exec clickhouse clickhouse-client --query "SELECT COUNT(*) FROM events" 2>/dev/null || echo "0")
    echo "   Events in ClickHouse: $EVENT_COUNT"
else
    echo "❌ ClickHouse connection failed"
fi

echo ""
echo "🎉 Setup verification complete!"
echo ""
echo "📊 Summary:"
echo "   - API Key: Configured ✅"
echo "   - Kafka Topics: $([ ${#missing_topics[@]} -eq 0 ] && echo "All present ✅" || echo "Some missing ⚠️")"
echo "   - Services: $([ -z "$UNHEALTHY" ] && echo "All running ✅" || echo "Some issues ⚠️")"
echo "   - Database: $([ "$CH_TEST" = "1" ] && echo "Connected ✅" || echo "Issues ❌")"
echo ""
echo "💡 If you see any issues:"
echo "   - Check logs: docker compose logs [service-name]"
echo "   - Restart consumer: docker compose restart flexprice-consumer"
echo "   - Reset everything: make reset"
echo "   - Clear frontend localStorage if events don't appear in UI"
