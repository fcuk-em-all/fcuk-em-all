# wizard/Dockerfile - FCUK-EM-ALL Control Plane, two-stage build.
# Stage 1: node:20-alpine (arm64 manifest digest) compiles the Vite/React SPA.
# Stage 2: python:3.13-slim (arm64 manifest digest) serves dist/ + the /api layer.
# Both digests are arm64; the amd64 appliance re-resolves its own manifest digests.

# ---- stage 1: frontend build ----
FROM node:20-alpine@sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293 AS frontend
WORKDIR /build
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build

# ---- stage 2: python runtime ----
FROM python:3.13-slim@sha256:6acbbb9fcc88069b075fb7c761e427df9c6ef0f11545035068939fa5c17fe8d3
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py ./
COPY --from=frontend /build/dist ./dist
# Source app.py may be mode 0600 on the host; make it importable by the non-root user.
RUN chmod 0644 app.py && useradd -r -u 10001 -s /usr/sbin/nologin wizard
USER wizard
EXPOSE 8088
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8088"]
