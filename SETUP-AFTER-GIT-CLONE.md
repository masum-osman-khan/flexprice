# Post-Git Clone Setup Guide for FlexPrice

This document provides the essential changes and setup steps needed after cloning the FlexPrice repository to avoid the event processing issues we encountered.

## Quick Setup (TL;DR)

```bash
# 1. Clone the repository
git clone <flexprice-repo-url>
cd flexprice

# 2. Run the setup script (creates Kafka topics and updates config)
./scripts/setup-after-clone.sh

# 3. Start the services
make up

# 4. Wait for services to be healthy, then test
./scripts/test-setup.sh
```

## Detailed Setup Steps

### 1. Required Changes to Make Before First Run

#### A. Update `internal/config/config.yaml`

**Add the working API key** to avoid authentication issues:

```yaml
# In the api_key.keys section, ensure this key exists:
"sk_01K5ZPDJXFH4CCZXF2QEQBY2AK":
  tenant_id: "00000000-0000-0000-0000-000000000000"
  user_id: "00000000-0000-0000-0000-000000000000"
  name: "Working API Key"
  is_active: true
```

#### B. Create Kafka Topics Automatically

The main issue was missing Kafka topics. We need to create them after Kafka starts but before the consumer tries to connect.

### 2. Docker Compose Improvements

#### A. Add Init Container for Kafka Topics

Add this service to `docker-compose.yml`:

```yaml
  kafka-init:
    image: confluentinc/cp-kafka:7.7.1
    depends_on:
      kafka:
        condition: service_healthy
    command: |
      bash -c "
        echo 'Creating Kafka topics...'
        kafka-topics --bootstrap-server kafka:9092 --create --if-not-exists --topic events --partitions 3 --replication-factor 1
        kafka-topics --bootstrap-server kafka:9092 --create --if-not-exists --topic events_post_processing --partitions 3 --replication-factor 1
        kafka-topics --bootstrap-server kafka:9092 --create --if-not-exists --topic events_post_processing_backfill --partitions 3 --replication-factor 1
        kafka-topics --bootstrap-server kafka:9092 --create --if-not-exists --topic feature_tracking_service_backfill --partitions 3 --replication-factor 1
        kafka-topics --bootstrap-server kafka:9092 --create --if-not-exists --topic system_events --partitions 3 --replication-factor 1
        echo 'Kafka topics created successfully!'
        kafka-topics --bootstrap-server kafka:9092 --list
      "
```

#### B. Update Consumer Dependencies

Modify the `flexprice-consumer` service to depend on the kafka-init:

```yaml
  flexprice-consumer:
    image: flexprice-app:local
    depends_on:
      postgres:
        condition: service_healthy
      kafka:
        condition: service_healthy
      clickhouse:
        condition: service_healthy
      temporal:
        condition: service_started
      kafka-init:
        condition: service_completed_successfully  # Add this line
    # ... rest of the configuration
```

### 3. Automation Scripts

#### A. Post-Clone Setup Script

Create `scripts/setup-after-clone.sh`:

```bash
#!/bin/bash
set -e

echo "🚀 Setting up FlexPrice after git clone..."

# Check if API key exists in config
if ! grep -q "sk_01K5ZPDJXFH4CCZXF2QEQBY2AK" internal/config/config.yaml; then
    echo "📝 Adding working API key to config.yaml..."
    
    # Create backup
    cp internal/config/config.yaml internal/config/config.yaml.backup
    
    # Add the API key using sed (or manual edit)
    cat >> temp_api_key.yaml << 'EOF'
      "sk_01K5ZPDJXFH4CCZXF2QEQBY2AK":
        tenant_id: "00000000-0000-0000-0000-000000000000"
        user_id: "00000000-0000-0000-0000-000000000000"
        name: "Working API Key"
        is_active: true
EOF
    
    # Insert after the existing API key
    sed '/name: "Dev API Keys"/,/is_active: true/{ /is_active: true/r temp_api_key.yaml
    }' internal/config/config.yaml.backup > internal/config/config.yaml
    
    rm temp_api_key.yaml
    echo "✅ API key added successfully"
else
    echo "✅ API key already exists in config"
fi

# Build the application first
echo "🔨 Building FlexPrice application..."
docker compose build flexprice-build

echo "🐳 Starting infrastructure services..."
docker compose up -d postgres kafka clickhouse temporal

echo "⏳ Waiting for services to be healthy..."
timeout=300
elapsed=0
while [ $elapsed -lt $timeout ]; do
    if docker compose ps --format json | jq -r '.[].Health' | grep -v "healthy" | grep -v "null" >/dev/null 2>&1; then
        echo "Services still starting... (${elapsed}s)"
        sleep 5
        elapsed=$((elapsed + 5))
    else
        echo "✅ Infrastructure services are healthy!"
        break
    fi
done

if [ $elapsed -ge $timeout ]; then
    echo "❌ Timeout waiting for services to be healthy"
    docker compose ps
    exit 1
fi

echo "🎯 Creating Kafka topics..."
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --create --if-not-exists --topic events --partitions 3 --replication-factor 1
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --create --if-not-exists --topic events_post_processing --partitions 3 --replication-factor 1
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --create --if-not-exists --topic events_post_processing_backfill --partitions 3 --replication-factor 1
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --create --if-not-exists --topic feature_tracking_service_backfill --partitions 3 --replication-factor 1
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --create --if-not-exists --topic system_events --partitions 3 --replication-factor 1

echo "📋 Verifying Kafka topics..."
docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --list

echo "🚀 Starting application services..."
docker compose up -d

echo "⏳ Waiting for application services to be ready..."
sleep 10

echo "✅ Setup complete! Services should be running on:"
echo "   - API: http://localhost:8080"
echo "   - Temporal UI: http://localhost:8088"
echo "   - Kafka UI: http://localhost:8084 (if using --profile dev)"
echo ""
echo "🧪 Run './scripts/test-setup.sh' to verify everything is working"
```

#### B. Setup Verification Script

Create `scripts/test-setup.sh`:

```bash
#!/bin/bash
set -e

echo "🧪 Testing FlexPrice setup..."

API_KEY="sk_01K5ZPDJXFH4CCZXF2QEQBY2AK"
BASE_URL="http://localhost:8080"

# Test 1: Health check
echo "1️⃣ Testing health endpoint..."
if curl -s "${BASE_URL}/health" | grep -q "ok"; then
    echo "✅ Health check passed"
else
    echo "❌ Health check failed"
    exit 1
fi

# Test 2: Create a test event
echo "2️⃣ Creating test event..."
EVENT_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/v1/events" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${API_KEY}" \
    -d '{
        "environment_id": "env_test_setup",
        "event_type": "setup_test",
        "properties": {
            "test": "setup_verification",
            "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"
        }
    }')

if echo "$EVENT_RESPONSE" | grep -q "error"; then
    echo "❌ Event creation failed: $EVENT_RESPONSE"
    exit 1
else
    echo "✅ Event created successfully"
fi

# Test 3: Wait for event processing
echo "3️⃣ Waiting for event processing..."
sleep 5

# Test 4: Retrieve events
echo "4️⃣ Retrieving events..."
EVENTS_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/v1/events/list" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${API_KEY}" \
    -d '{
        "environment_id": "env_test_setup",
        "limit": 10
    }')

if echo "$EVENTS_RESPONSE" | grep -q '"total_count":0'; then
    echo "⚠️  Events not found yet. This might indicate:"
    echo "   - Events are still being processed (try again in a few seconds)"
    echo "   - Environment ID mismatch (check frontend localStorage)"
    echo "   - Consumer issues (check logs with: docker compose logs flexprice-consumer)"
else
    echo "✅ Events retrieved successfully"
fi

# Test 5: Check Kafka topics
echo "5️⃣ Verifying Kafka topics..."
TOPICS=$(docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --list 2>/dev/null)
required_topics=("events" "events_post_processing" "events_post_processing_backfill" "feature_tracking_service_backfill" "system_events")

for topic in "${required_topics[@]}"; do
    if echo "$TOPICS" | grep -q "^${topic}$"; then
        echo "✅ Topic '$topic' exists"
    else
        echo "❌ Topic '$topic' missing"
        exit 1
    fi
done

# Test 6: Check services
echo "6️⃣ Checking service status..."
if docker compose ps --format json | jq -r '.[] | select(.State != "running") | .Name' | grep -q .; then
    echo "⚠️  Some services are not running:"
    docker compose ps --format json | jq -r '.[] | select(.State != "running") | "\(.Name): \(.State)"'
else
    echo "✅ All services are running"
fi

echo ""
echo "🎉 Setup verification complete!"
echo ""
echo "💡 If you see any issues:"
echo "   - Check logs: docker compose logs [service-name]"
echo "   - Restart consumer: docker compose restart flexprice-consumer"
echo "   - Clear frontend localStorage if events don't appear in UI"
```

### 4. Updated Makefile Commands

Add these targets to your `Makefile`:

```makefile
.PHONY: setup
setup:
	@echo "Setting up FlexPrice after git clone..."
	@./scripts/setup-after-clone.sh

.PHONY: test-setup
test-setup:
	@echo "Testing FlexPrice setup..."
	@./scripts/test-setup.sh

.PHONY: reset
reset:
	@echo "Resetting FlexPrice environment..."
	@docker compose down -v
	@docker system prune -f
	@make setup
```

### 5. Environment Variables (Optional)

Create `.env.example` file:

```env
# FlexPrice Configuration
FLEXPRICE_API_KEY=sk_01K5ZPDJXFH4CCZXF2QEQBY2AK
FLEXPRICE_ENVIRONMENT_ID=env_01K5ZPD3WGG2DKDXBZ2VDB0DSG

# Database URLs (for external access)
POSTGRES_URL=postgresql://flexprice:flexprice123@localhost:5432/flexprice
CLICKHOUSE_URL=http://flexprice:flexprice123@localhost:8123/flexprice
KAFKA_BROKERS=localhost:29092

# Development
DEBUG=true
LOG_LEVEL=debug
```

## Summary of Changes Needed

### Immediate Changes for New Clones:

1. **Create automation scripts** (`setup-after-clone.sh`, `test-setup.sh`)
2. **Update docker-compose.yml** to include kafka-init service
3. **Ensure API key is in config.yaml** 
4. **Add Makefile targets** for easy setup and testing

### Commands After Git Clone:

```bash
git clone <repo>
cd flexprice
chmod +x scripts/*.sh
./scripts/setup-after-clone.sh  # Handles everything
make test-setup                 # Verify it works
```

This setup eliminates the manual steps we had to do and ensures new developers can get up and running without encountering the Kafka topic or API key issues.
