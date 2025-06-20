# Usa la imagen base recomendada por Home Assistant
ARG BUILD_FROM
FROM ${BUILD_FROM}

ENV LANG C.UTF-8

# Instalar dependencias del sistema operativo
RUN apk add --no-cache \
    bash \
    git \
    python3 \
    py3-pip \
    mosquitto-clients \
    jq \
    wget \
    ca-certificates

# Instalar bashio manualmente
RUN wget -O /usr/lib/bashio.sh https://raw.githubusercontent.com/hassio-addons/bashio/main/bashio.sh

# Clonar el repositorio del bridge (cambiar a tu fork si es necesario)
RUN git clone https://github.com/elvis-epx/alarme-intelbras.git /alarme-intelbras

# Copiar el script de arranque
COPY run.sh /run.sh
RUN chmod +x /run.sh

# Comando de inicio del add-on
CMD [ "/run.sh" ]
