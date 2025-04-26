# Dockerfile
FROM maven:3.9.6-eclipse-temurin-21

RUN apt-get update && \
    apt-get install -y --no-install-recommends docker.io && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
