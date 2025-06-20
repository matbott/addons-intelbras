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

# Instalar bashio usando el método oficial
RUN curl -sSL https://github.com/hassio-addons/bashio/releases/latest/download/bashio.tar.gz | \
    tar -xz -C /usr/local/bin/

# Clonar el proyecto
RUN git clone https://github.com/elvis-epx/alarme-intelbras.git /alarme-intelbras

# Copiar y dar permisos al script principal
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD [ "/run.sh" ]
