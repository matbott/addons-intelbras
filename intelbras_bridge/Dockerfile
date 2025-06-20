ARG BUILD_FROM=ghcr.io/hassio-addons/base:17.2.5
FROM ${BUILD_FROM}
ENV LANG C.UTF-8

# Instalar paquetes necesarios
RUN apk add --no-cache \
    bash \
    git \
    python3 \
    py3-pip \
    mosquitto-clients \
    jq \
    curl \
    ca-certificates

# Instalar bashio - limpiar primero si existe
RUN rm -rf /usr/lib/bashio* && \
    mkdir -p /tmp/bashio && \
    curl -sSL https://github.com/hassio-addons/bashio/archive/main.tar.gz | \
    tar -xz --strip-components=1 -C /tmp/bashio && \
    cp -r /tmp/bashio/lib/* /usr/lib/ && \
    chmod +x /usr/lib/bashio && \
    rm -rf /tmp/bashio

# Clonar el proyecto
RUN git clone https://github.com/elvis-epx/alarme-intelbras.git /alarme-intelbras

# Copiar y dar permisos al script principal
COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
