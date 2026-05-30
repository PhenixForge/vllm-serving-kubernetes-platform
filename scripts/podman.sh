toolbox list
toolbox enter vllm-serving
cd /var/home/revan/labs/vllm-serving-kubernetes-platform/container
podman build -t vllm-serving:0.1.0 -f Containerfile .
podman tag vllm-serving:0.1.0 vllm-serving:latest