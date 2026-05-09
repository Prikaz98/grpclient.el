#!/usr/bin/env bash
set -e

# Change to the directory of the script
cd "$(dirname "$0")"

echo "Setting up virtual environment..."
python3 -m venv .venv
source .venv/bin/activate

echo "Installing dependencies..."
pip install -r server/requirements.txt --quiet

echo "Generating Python gRPC code from .proto files..."
python -m grpc_tools.protoc -I. --python_out=./server --grpc_python_out=./server hello.proto hello_v3.proto

echo "Starting gRPC server..."
python server/server.py
