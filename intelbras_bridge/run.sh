#!/usr/bin/with-contenv bashio

bashio::log.info "--- INICIANDO DIAGNÓSTICO FINAL DE COMPATIBILIDAD ---"

bashio::log.info "1. Arquitectura del sistema donde corre Home Assistant:"
echo "------------------------------------------------------"
bashio::log.info "$(uname -m)"
echo "------------------------------------------------------"
bashio::log.info "(Ej: aarch64 es Raspberry Pi 4, x86_64 o amd64 es un PC/NUC/VM)"
echo ""

bashio::log.info "2. Analizando el archivo 'comandar':"
echo "------------------------------------------------------"
if [ -f /alarme-intelbras/comandar ]; then
    # Usamos el comando 'file' para inspeccionar el tipo de ejecutable
    file /alarme-intelbras/comandar
else
    bashio::log.error "El archivo '/alarme-intelbras/comandar' no fue encontrado."
fi
echo "------------------------------------------------------"
echo ""

bashio::log.info "3. Analizando el archivo 'receptorip':"
echo "------------------------------------------------------"
if [ -f /alarme-intelbras/receptorip ]; then
    file /alarme-intelbras/receptorip
else
    bashio::log.error "El archivo '/alarme-intelbras/receptorip' no fue encontrado."
fi
echo "------------------------------------------------------"
echo ""


bashio::log.warning "--- FIN DEL DIAGNÓSTICO ---"
bashio::log.warning "El addon se detendrá ahora. Por favor, copia y pega todo el log."

# Detenemos la ejecución aquí a propósito.
exit 0
