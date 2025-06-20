ARG BUILD_FROM
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

# Instalar bashio - crear directorio primero
RUN mkdir -p /tmp/bashio && \
    curl -sSL https://github.com/hassio-addons/bashio/archive/main.tar.gz | \
    tar -xz --strip-components=1 -C /tmp/bashio && \
    cp -r /tmp/bashio/lib/* /usr/lib/ && \
    chmod +x /usr/lib/bashio && \
    rm -rf /tmp/bashio

# Clonar el proyecto
RUN git clone https://github.com/elvis-epx/alarme-intelbras.git /alarme-intelbras

# Copiar y dar permisos al script principal
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD [ "/run.sh" ]
