ARG PG_MAJOR=16
FROM postgres:${PG_MAJOR}-bookworm

ARG PG_MAJOR=16
ENV PG_MAJOR=${PG_MAJOR}
ENV PATH=/usr/lib/postgresql/${PG_MAJOR}/bin:$PATH

# ca-certificates: RDS TLS. procps/coreutils: timing + progress in the scripts.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates procps coreutils \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

WORKDIR /backups
ENTRYPOINT ["/bin/bash"]
CMD ["/scripts/dump.sh"]
