# Define the service name (optional)
#SERVICE_NAME = my_service

# Rebuild and restart containers
up:
	docker compose up -d --build

# Shut down the services
down:
	docker compose down

# Restart the services (stop, then start)
restart: down up

# Show the logs
logs:
	docker compose logs -f

# Optional: Clean volumes and containers
clean:
	docker compose down -v --remove-orphans

