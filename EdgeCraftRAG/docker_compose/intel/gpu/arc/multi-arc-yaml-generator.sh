#!/bin/bash
# Copyright (C) 2024 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 DP_NUM output-file-path"
    exit 1
fi

# Get the port number from the command line argument
PORT_NUM=$1

# Start generating the Nginx configuration
cat <<EOL > $2
# Copyright (C) 2024 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

services:
  etcd:
    container_name: milvus-etcd
    image: quay.io/coreos/etcd:v3.5.5
    environment:
      - ETCD_AUTO_COMPACTION_MODE=revision
      - ETCD_AUTO_COMPACTION_RETENTION=1000
      - ETCD_QUOTA_BACKEND_BYTES=4294967296
      - ETCD_SNAPSHOT_COUNT=50000
    volumes:
      - \${DOCKER_VOLUME_DIRECTORY:-\${PWD}}/volumes/etcd:/etcd
    command: etcd -advertise-client-urls=http://127.0.0.1:2379 -listen-client-urls http://0.0.0.0:2379 --data-dir /etcd
    healthcheck:
      test: ["CMD", "etcdctl", "endpoint", "health"]
      interval: 30s
      timeout: 20s
      retries: 3
    deploy:
      replicas: \${MILVUS_ENABLED:-0}
  minio:
    container_name: milvus-minio
    image: minio/minio:RELEASE.2023-03-20T20-16-18Z
    environment:
      MINIO_ACCESS_KEY: minioadmin
      MINIO_SECRET_KEY: minioadmin
    ports:
      - "\${MINIO_PORT1:-5044}:9001"
      - "\${MINIO_PORT2:-5043}:9000"
    volumes:
      - \${DOCKER_VOLUME_DIRECTORY:-\${PWD}}/volumes/minio:/minio_data
    command: minio server /minio_data --console-address ":9001"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 20s
      retries: 3
    deploy:
      replicas: \${MILVUS_ENABLED:-0}
  milvus-standalone:
    container_name: milvus-standalone
    image: milvusdb/milvus:v2.4.6
    command: ["milvus", "run", "standalone"]
    security_opt:
      - seccomp:unconfined
    environment:
      ETCD_ENDPOINTS: etcd:2379
      MINIO_ADDRESS: minio:9000
    volumes:
      - ./milvus.yaml:/milvus/configs/milvus.yaml
      - \${DOCKER_VOLUME_DIRECTORY:-\${PWD}}/volumes/milvus:/var/lib/milvus
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9091/healthz"]
      interval: 30s
      start_period: 90s
      timeout: 20s
      retries: 3
    ports:
      - "19530:19530"
      - "\${MILVUS_STANDALONE_PORT:-9091}:9091"
    depends_on:
      - "etcd"
      - "minio"
    deploy:
      replicas: \${MILVUS_ENABLED:-0}
  edgecraftrag-server:
    image: \${REGISTRY:-opea}/edgecraftrag-server:\${TAG:-latest}
    container_name: edgecraftrag-server
    environment:
      no_proxy: \${no_proxy}
      http_proxy: \${http_proxy}
      https_proxy: \${https_proxy}
      HF_ENDPOINT: \${HF_ENDPOINT}
      vLLM_ENDPOINT: \${vLLM_ENDPOINT:-http://\${HOST_IP}:\${NGINX_PORT:-8086}}
      LLM_MODEL: \${LLM_MODEL}
      ENABLE_BENCHMARK: \${ENABLE_BENCHMARK:-false}
      MAX_MODEL_LEN: \${MAX_MODEL_LEN:-5000}
      CHAT_HISTORY_ROUND: \${CHAT_HISTORY_ROUND:-0}
    volumes:
      - \${MODEL_PATH:-\${PWD}}:/home/user/models
      - \${DOC_PATH:-\${PWD}}:/home/user/docs
      - \${TMPFILE_PATH:-\${PWD}}:/home/user/ui_cache
      - \${HF_CACHE:-\${HOME}/.cache}:/home/user/.cache
      - \${PROMPT_PATH:-\${PWD}}:/templates/custom
    restart: always
    ports:
      - \${PIPELINE_SERVICE_PORT:-16010}:\${PIPELINE_SERVICE_PORT:-16010}
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - \${VIDEOGROUPID:-44}
      - \${RENDERGROUPID:-109}
  ecrag:
    image: \${REGISTRY:-opea}/edgecraftrag:\${TAG:-latest}
    container_name: edgecraftrag
    environment:
      no_proxy: \${no_proxy}
      http_proxy: \${http_proxy}
      https_proxy: \${https_proxy}
      MEGA_SERVICE_PORT: \${MEGA_SERVICE_PORT:-16011}
      MEGA_SERVICE_HOST_IP: \${MEGA_SERVICE_HOST_IP:-\${HOST_IP}}
      PIPELINE_SERVICE_PORT: \${PIPELINE_SERVICE_PORT:-16010}
      PIPELINE_SERVICE_HOST_IP: \${PIPELINE_SERVICE_HOST_IP:-\${HOST_IP}}
    restart: always
    ports:
      - \${MEGA_SERVICE_PORT:-16011}:\${MEGA_SERVICE_PORT:-16011}
    depends_on:
      - edgecraftrag-server
  nginx:
    image: nginx:latest
    restart: always
    ports:
      - \${NGINX_PORT:-8086}:8086
    volumes:
      - \${NGINX_CONFIG_PATH:-\${PWD}}:/etc/nginx/nginx.conf
    depends_on:
      - edgecraftrag-server
  edgecraftrag-ui:
    image: \${REGISTRY:-opea}/edgecraftrag-ui:\${TAG:-latest}
    container_name: edgecraftrag-ui
    environment:
      no_proxy: \${no_proxy}
      http_proxy: \${http_proxy}
      https_proxy: \${https_proxy}
      MEGA_SERVICE_PORT: \${MEGA_SERVICE_PORT:-16011}
      MEGA_SERVICE_HOST_IP: \${MEGA_SERVICE_HOST_IP:-\${HOST_IP}}
      PIPELINE_SERVICE_PORT: \${PIPELINE_SERVICE_PORT:-16010}
      PIPELINE_SERVICE_HOST_IP: \${PIPELINE_SERVICE_HOST_IP:-\${HOST_IP}}
      UI_SERVICE_PORT: \${UI_SERVICE_PORT:-8082}
      UI_SERVICE_HOST_IP: \${UI_SERVICE_HOST_IP:-0.0.0.0}
    volumes:
      - \${TMPFILE_PATH:-\${PWD}}:/home/user/ui_cache
    restart: always
    ports:
      - \${UI_SERVICE_PORT:-8082}:\${UI_SERVICE_PORT:-8082}
    depends_on:
      - edgecraftrag-server
      - ecrag
EOL

for ((i = 0; i < PORT_NUM; i++)); do
    cat <<EOL >> $2
  llm-serving-xpu-$i:
    container_name: ipex-llm-serving-xpu-container-$i
    image: intelanalytics/ipex-llm-serving-xpu:0.8.3-b20
    privileged: true
    restart: always
    ports:
      - \${VLLM_SERVICE_PORT_$i:-8$((i+1))00}:\${VLLM_SERVICE_PORT_$i:-8$((i+1))00}
    group_add:
      - video
      - \${VIDEOGROUPID:-44}
      - \${RENDERGROUPID:-109}
    volumes:
      - \${LLM_MODEL_PATH:-\${MODEL_PATH}/\${LLM_MODEL}}:/llm/models
    devices:
      - /dev/dri
    environment:
      no_proxy: \${no_proxy}
      http_proxy: \${http_proxy}
      https_proxy: \${https_proxy}
      HF_ENDPOINT: \${HF_ENDPOINT}
      MODEL_PATH: "/llm/models"
      SERVED_MODEL_NAME: \${LLM_MODEL}
      TENSOR_PARALLEL_SIZE: \${TENSOR_PARALLEL_SIZE:-1}
      MAX_NUM_SEQS: \${MAX_NUM_SEQS:-64}
      MAX_NUM_BATCHED_TOKENS: \${MAX_NUM_BATCHED_TOKENS:-5000}
      MAX_MODEL_LEN: \${MAX_MODEL_LEN:-5000}
      LOAD_IN_LOW_BIT: \${LOAD_IN_LOW_BIT:-fp8}
      CCL_DG2_USM: \${CCL_DG2_USM:-""}
      PORT: \${VLLM_SERVICE_PORT_$i:-8$((i+1))00}
      ZE_AFFINITY_MASK: \${SELECTED_XPU_$i:-$i}
    shm_size: '32g'
    entrypoint: /bin/bash -c "\\
      cd /llm && \\
      bash start-vllm-service.sh"
EOL
done
cat <<EOL >> $2
networks:
  default:
    driver: bridge
EOL

echo "compose_vllm.yaml generated"
