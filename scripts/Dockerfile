FROM python:3.12-slim

RUN pip install --no-cache-dir fonttools && \
    apt-get update && apt-get install -y --no-install-recommends woff2 curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /site
