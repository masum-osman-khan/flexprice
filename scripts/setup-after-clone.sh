#!/bin/bash
set -e

echo "🚀 Setting up FlexPrice after git clone..."

# Check if API key exists in config
if ! grep -q "sk_01K5ZPDJXFH4CCZXF2QEQBY2AK" internal/config/config.yaml; then
    echo "📝 Adding working API key to config.yaml..."
    
    # Create backup
    cp internal/config/config.yaml internal/config/config.yaml.backup
    
    # Add the API key using a more reliable method
    python3 -c "
import yaml
import sys

# Read the config file
with open('internal/config/config.yaml', 'r') as f:
    config = yaml.safe_load(f)

# Add the new API key
if 'auth' not in config:
    config['auth'] = {}
if 'api_key' not in config['auth']:
    config['auth']['api_key'] = {}
if 'keys' not in config['auth']['api_key']:
    config['auth']['api_key']['keys'] = {}

# Add the working API key
config['auth']['api_key']['keys']['sk_01K5ZPDJXFH4CCZXF2QEQBY2AK'] = {
    'tenant_id': '00000000-0000-0000-0000-000000000000',
    'user_id': '00000000-0000-0000-0000-000000000000',
    'name': 'Working API Key',
    'is_active': True
}

# Write back to file
with open('internal/config/config.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

print('✅ API key added successfully')
" || {
        echo "⚠️  Python3/PyYAML not available, using manual method..."
        # Fallback to manual sed approach
        cat >> temp_api_key.yaml << 'EOF'
      "sk_01K5ZPDJXFH4CCZXF2QEQBY2AK":
        tenant_id: "00000000-0000-0000-0000-000000000000"
        user_id: "00000000-0000-0000-0000-000000000000"
        name: "Working API Key"
        is_active: true
EOF
        
        # Insert after the last API key entry
        sed '/is_active: true/r temp_api_key.yaml' internal/config/config.yaml.backup > internal/config/config.yaml
        rm temp_api_key.yaml
        echo "✅ API key added using fallback method"
    }
else
    echo "✅ API key already exists in config"
fi

# Build the application first
echo "🔨 Building FlexPrice application..."
docker compose build

echo "🐳 Starting infrastructure services..."
docker compose up -d postgres kafka clickhouse temporal

echo "⏳ Waiting for services to be healthy..."
timeout=300
elapsed=0
while [ $elapsed -lt $timeout ]; do
    healthy_services=$(docker compose ps --format json | jq -r '.[] | select(.Health == "healthy" or .Health == null) | .Name' | wc -l)
    total_services=$(docker compose ps --format json | jq -r '.[].Name' | wc -l)
    
    if [ "$healthy_services" -eq "$total_services" ]; then
        echo "✅ Infrastructure services are healthy!"
        break
    else
        echo "Services still starting... (${elapsed}s) - $healthy_services/$total_services healthy"
        sleep 5
        elapsed=$((elapsed + 5))
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
sleep 15

echo "✅ Setup complete! Services should be running on:"
echo "   - API: http://localhost:8080"
echo "   - Temporal UI: http://localhost:8088"
echo "   - Kafka UI: http://localhost:8084 (if using --profile dev)"
echo ""
echo "🧪 Run './scripts/test-setup.sh' to verify everything is working"
echo ""
echo "📋 Next steps:"
echo "   1. Test the setup: make test-setup"
echo "   2. Access the API at http://localhost:8080"
echo "   3. Check logs if needed: docker compose logs [service-name]"
