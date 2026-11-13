#!/usr/bin/bash

# Verify
kubectl version --client
kind version
helm version

trap "exit 0" SIGTERM SIGINT;
while true; do sleep 10 & wait $!; done
