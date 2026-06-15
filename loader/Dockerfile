FROM ghcr.io/osgeo/gdal:ubuntu-small-latest
RUN apt-get update \
  && apt-get install -y --no-install-recommends postgresql-client curl \
  && rm -rf /var/lib/apt/lists/*
COPY load.sh /load.sh
RUN chmod +x /load.sh
ENTRYPOINT ["/load.sh"]
