#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
IMAGE_NAME="tf-visualizer"
CONTAINER_NAME="tf-visualizer"
HOST_PORT="${PORT:-5001}"
CONTAINER_PORT="5001"

# Default repo path: parent of this script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO="$(dirname "$SCRIPT_DIR")"

# ─── Parse arguments ─────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --repo PATH    Path to Terraform repository (default: $DEFAULT_REPO)"
  echo "  --port PORT    Host port to bind (default: $HOST_PORT)"
  echo "  --no-build     Skip image build (use existing image)"
  echo "  --stop         Stop and remove the running container"
  echo "  --logs         Show container logs"
  echo "  -h, --help     Show this help"
  exit 0
}

REPO_PATH="$DEFAULT_REPO"
NO_BUILD=false
ACTION="run"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)   REPO_PATH="$2"; shift 2 ;;
    --port)   HOST_PORT="$2"; shift 2 ;;
    --no-build) NO_BUILD=true; shift ;;
    --stop)   ACTION="stop"; shift ;;
    --logs)   ACTION="logs"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ─── Detect container runtime ────────────────────────────────────────────────
if command -v podman &>/dev/null; then
  CTR="podman"
elif command -v docker &>/dev/null; then
  CTR="docker"
else
  echo "Error: Neither podman nor docker found. Please install one of them." >&2
  exit 1
fi

echo "Using: $CTR"

# ─── Actions ─────────────────────────────────────────────────────────────────
if [[ "$ACTION" == "stop" ]]; then
  echo "Stopping container '$CONTAINER_NAME'..."
  $CTR stop "$CONTAINER_NAME" 2>/dev/null && echo "Stopped." || echo "Container not running."
  $CTR rm  "$CONTAINER_NAME" 2>/dev/null && echo "Removed." || true
  exit 0
fi

if [[ "$ACTION" == "logs" ]]; then
  $CTR logs -f "$CONTAINER_NAME"
  exit 0
fi

# ─── Validate repo path ───────────────────────────────────────────────────────
REPO_PATH="$(cd "$REPO_PATH" && pwd)"
if [[ ! -d "$REPO_PATH" ]]; then
  echo "Error: Repo path does not exist: $REPO_PATH" >&2
  exit 1
fi

echo "Repository: $REPO_PATH"
echo "URL: http://localhost:$HOST_PORT"
echo ""

# ─── Build ───────────────────────────────────────────────────────────────────
if [[ "$NO_BUILD" == false ]]; then
  echo "Building image '$IMAGE_NAME'..."
  $CTR build -t "$IMAGE_NAME" "$SCRIPT_DIR"
  echo ""
fi

# ─── Stop existing container (if any) ────────────────────────────────────────
if $CTR inspect "$CONTAINER_NAME" &>/dev/null; then
  echo "Stopping existing container '$CONTAINER_NAME'..."
  $CTR stop "$CONTAINER_NAME" &>/dev/null || true
  $CTR rm   "$CONTAINER_NAME" &>/dev/null || true
fi

# ─── Run ─────────────────────────────────────────────────────────────────────
echo "Starting container '$CONTAINER_NAME'..."
$CTR run -d \
  --name "$CONTAINER_NAME" \
  -p "${HOST_PORT}:${CONTAINER_PORT}" \
  -v "${REPO_PATH}:/repo:ro" \
  "$IMAGE_NAME"

echo ""
echo "Container started. Open: http://localhost:$HOST_PORT"
echo ""
echo "Useful commands:"
echo "  $0 --logs          # Follow logs"
echo "  $0 --stop          # Stop container"
echo "  $0 --no-build      # Restart without rebuilding"
