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

# Instalar bashio (solo el archivo necesario)
RUN mkdir -p /usr/lib/bashio && \
    curl -sSL https://raw.githubusercontent.com/hassio-addons/bashio/main/lib/bashio.sh -o /usr/lib/bashio/bashio.sh && \
    chmod +x /usr/lib/bashio/bashio.sh

# Clonar el proyecto (si lo necesitás dentro del contenedor)
RUN git clone https://github.com/elvis-epx/alarme-intelbras.git /alarme-intelbras
RUN chmod +x /alarme-intelbras/comandar
WORKDIR /alarme-intelbras
RUN make

# Copiar y dar permisos al script principal
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD [ "/run.sh" ]
