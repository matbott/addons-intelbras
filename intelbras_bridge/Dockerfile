ARG BUILD_FROM
FROM ${BUILD_FROM}

# Instalar dependencias esenciales del sistema operativo
RUN apk add --no-cache bashio git python3 py3-pip mosquitto-clients jq

# Clonar el repositorio de alarme-intelbras
# MÁS ADELANTE, REEMPLAZA ESTA LÍNEA CON LA URL DE TU FORK DE GITHUB
RUN git clone https://github.com/elvis-epx/alarme-intelbras.git /alarme-intelbras

# Copiar nuestro script de ejecución al contenedor
COPY run.sh /
RUN chmod a+x /run.sh

# Ejecutar nuestro script cuando el contenedor del Add-on inicie
CMD [ "/run.sh" ]
