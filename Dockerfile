# uv is already in this base image, so no pip bootstrap step.
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

WORKDIR /app

# Deps in their own layer: this cache survives every source edit and is only
# invalidated by a lockfile change. --frozen = fail if uv.lock disagrees with
# pyproject, rather than silently resolving something new inside CI.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project

COPY poller.py webhook.py ./
ENV PATH=/app/.venv/bin:$PATH

# Default process is the receiver; the poller is the same image, different command:
#   docker run --rm IMAGE python poller.py
CMD ["uvicorn", "webhook:app", "--host", "0.0.0.0", "--port", "8000"]
