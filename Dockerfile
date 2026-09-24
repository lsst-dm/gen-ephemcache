# Ephemerides cache generator

ARG BASE_CONTAINER=docker.io/condaforge/miniforge3
ARG TAG=26.7.2-0
FROM ${BASE_CONTAINER}:${TAG}

ENV PYTHONWARNINGS="ignore:The TestRunner" \
    PYTHONUNBUFFERED=1 \
    HOME=/tmp \
    MPLCONFIGDIR=/app/outputs/.matplotlib \
    KIND="parallel" \
    ENV="ephemcache" \
    MAMBA="mamba" \
    EPHEMCACHE_OUTPUT_DIR="/app/outputs"

ARG MPSKY_TAG=main

# GNU parallel is NOT in the base image, and compute-ephem-cache.sh needs it
# for the KIND=parallel fan-out. tzdata is required too: without it glibc
# does NOT error on TZ=America/Santiago, it silently stays on UTC, and the
# 17:00 night rollover then computes the wrong observing night.
#
# APT::Sandbox::User=root: apt normally drops privileges to _apt (uid 42),
# which fails under a single-uid rootless podman mapping (no subuid range on
# USDF). Harmless under rootful docker, so it stays in the committed file.
RUN apt-get -o APT::Sandbox::User=root update \
 && apt-get -o APT::Sandbox::User=root install -y --no-install-recommends \
      parallel \
      tzdata \
      git \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

WORKDIR /app
COPY . /app

# Remove --bar from parallel command (incompatible with pod /dev/tty)
RUN sed -i 's/parallel --halt now,fail=1 --bar /parallel --halt now,fail=1 /' \
      /app/bin/compute-ephem-cache.sh

# Conda Environment
COPY conda-requirements.txt /tmp/conda-requirements.txt

RUN mamba create -n ephemcache -c conda-forge \
    --file /tmp/conda-requirements.txt \
    --yes \
 && conda clean -afy \
 && rm /tmp/conda-requirements.txt

# Validation
RUN . /opt/conda/etc/profile.d/conda.sh && conda activate ephemcache \
 && python -c "import sorcha; print(sorcha.__version__)" \
 && python -c "import rebound; print(rebound.__version__)" \
 && python -c "import assist; print('assist OK')"

# Run sorcha bootstrap to generate sorcha caches
RUN . /opt/conda/etc/profile.d/conda.sh && conda activate ephemcache \
 && cd /app \
 && sorcha bootstrap --cache sorcha_cache \
 && chmod -R a+rX /app/sorcha_cache

# Python Dependencies
RUN . /opt/conda/etc/profile.d/conda.sh && conda activate ephemcache \
 && echo "MPSKY_TAG is: ${MPSKY_TAG}" \
 && git clone -b ${MPSKY_TAG} https://github.com/lsst-dm/mpsky.git \
 && cd mpsky \
 && pip install -e . \
 && cd /app

# Ephemcache Configuration File
RUN cat > /app/ephemcache.config << 'EOF'
ENV=ephemcache
KIND=parallel
MAMBA=mamba
MPCDB="postgresql+psycopg2://mpcorb-db.slac.stanford.edu/mpc_sbn"
EOF

# Directory and Permissions
RUN mkdir -p /app/outputs/caches \
             /app/outputs/catalogs \
             /app/outputs/logs \
             /app/outputs/.matplotlib \
 && chmod 755 /app/outputs \
 && mkdir -p /tmp/matplotlib \
 && chmod 1777 /tmp/matplotlib

# Make entrypoint executable
RUN chmod +x /app/bin/container-entrypoint.sh

# Entrypoint
ENTRYPOINT ["/app/bin/container-entrypoint.sh"]
CMD ["run"]