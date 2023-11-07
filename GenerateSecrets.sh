#!/bin/bash

# Define the names of your secrets
secrets=("postgress_password" "redis_password")

# Generate a random password for each secret and create the secrets
for secret in "${secrets[@]}"; do
    # Generate a random password (12 characters in this example)
    random_password=$(openssl rand -base64 12)

    # Create the Docker secret with the random password
    echo "$random_password" | docker secret create "$secret" -
    
    echo "Created secret $secret"
done
