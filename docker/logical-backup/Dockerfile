FROM ubuntu:18.04
LABEL maintainer="Team ACID @ Zalando <team-acid@zalando.de>"
ENV PATH="/root/.cargo/bin:$PATH"
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update     \
    && apt-get install --no-install-recommends -y \
        apt-utils \
        build-essential \
        ca-certificates \
        lsb-release \
        pigz \
        python3-pip \
        python3-setuptools \
        curl \
        jq \
        gnupg \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > /usr/local/share/rustup.sh \
    && sh /usr/local/share/rustup.sh -y --no-modify-path \
    && cargo install saltlick-cli \
    && rm -rf /root/.cargo/registry \
    && pip3 install --no-cache-dir awscli --upgrade \
    && echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && cat /etc/apt/sources.list.d/pgdg.list \
    && curl --silent https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
    && apt-get update \
    && apt-get install --no-install-recommends -y  \
        postgresql-client-11  \
        postgresql-client-10  \
        postgresql-client-9.6 \
        postgresql-client-9.5 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY dump.sh ./
COPY restore.sh ./

ENV PG_DIR=/usr/lib/postgresql/

ENTRYPOINT ["/dump.sh"]
