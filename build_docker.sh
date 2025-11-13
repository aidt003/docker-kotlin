#!/bin/sh

DOCKER_TAG=${1:?"Usage: $0 <docker-tag>"}

docker build --platform linux/amd64 -t "$DOCKER_TAG" .