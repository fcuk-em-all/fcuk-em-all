# importer/Dockerfile - FCUK-EM-ALL universal media importer runtime (29.sh).
# Deps-only image: the logic lives in lib/importer.py, mounted at run-time, so it
# can be iterated without a rebuild. Built locally (NOT a registry pull); base is
# pinned by the same arm64 python:3.13-slim digest the wizard already validated
# (amd64 appliance re-resolves the linux/amd64 base digest).
FROM python:3.13-slim@sha256:6acbbb9fcc88069b075fb7c761e427df9c6ef0f11545035068939fa5c17fe8d3

# ffmpeg -> ffprobe (container title tags); libchromaprint-tools -> fpcalc (AcoustID)
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg libchromaprint-tools \
 && rm -rf /var/lib/apt/lists/*

# pinned python deps (guessit pulls rebulk/babelfish; mutagen for tags; requests)
RUN pip install --no-cache-dir guessit==3.8.0 mutagen==1.47.0 requests==2.32.3

WORKDIR /
ENTRYPOINT ["python", "/importer.py"]
