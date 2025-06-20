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

# Instalar bashio manualmente
RUN curl -sSL -o /usr/lib/bashio.sh https://raw.githubusercontent.com/hassio-addons/bashio/main/lib/bashio.sh

# Clonar el proyecto (cambiar a tu fork si querés)
RUN git clone https://github.com/elvis-epx/alarme-intelbras.git /alarme-intelbras

# Copiar y dar permisos al script principal
COPY run.sh /run.sh
RUN chmod +x /run.sh

# Comando principal
CMD [ "/run.sh" ]
