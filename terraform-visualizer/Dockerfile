FROM python:3.12-slim

# Install system dependencies + Terraform
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl unzip ca-certificates \
    && TERRAFORM_VERSION=$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['current_version'])") \
    && ARCH=$(uname -m) \
    && case "$ARCH" in \
        x86_64)  TF_ARCH=amd64 ;; \
        aarch64) TF_ARCH=arm64 ;; \
        arm*)    TF_ARCH=arm   ;; \
        *)       TF_ARCH=amd64 ;; \
    esac \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TF_ARCH}.zip" \
        -o /tmp/terraform.zip \
    && unzip /tmp/terraform.zip -d /usr/local/bin \
    && rm /tmp/terraform.zip \
    && apt-get remove -y unzip \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY server.py .
COPY parser/ parser/
COPY static/ static/

# Repo is mounted at /repo at runtime
VOLUME ["/repo"]

EXPOSE 5001

CMD ["python", "server.py", "--repo", "/repo", "--host", "0.0.0.0", "--port", "5001"]
