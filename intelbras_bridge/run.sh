#!/usr/bin/with-contenv bashio

# Función para logging con timestamp
log_with_timestamp() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Función para cleanup al salir
cleanup() {
    log_with_timestamp "Shutting down addon..."
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "offline" 2>/dev/null || true
    exit 0
}

# Capturar señales para cleanup
trap cleanup SIGTERM SIGINT

log_with_timestamp "=== Starting Intelbras MQTT Bridge Add-on ==="

# --- CARGAR Y VALIDAR CONFIGURACIÓN ---
log_with_timestamp "Loading configuration..."

ALARM_IP=$(bashio::config 'alarm_ip')
ALARM_PORT=$(bashio::config 'alarm_port')
ALARM_PASS=$(bashio::config 'alarm_password')
PASS_LEN=$(bashio::config 'password_length')
ZONE_COUNT=$(bashio::config 'zone_count')
POLLING_INTERVAL_MIN=$(bashio::config 'polling_interval_minutes')
BROKER=$(bashio::config 'mqtt_broker')
PORT=$(bashio::config 'mqtt_port')
USER=$(bashio::config 'mqtt_user')
PASS=$(bashio::config 'mqtt_password')

# Mostrar configuración (sin mostrar passwords completas)
log_with_timestamp "Configuration loaded:"
log_with_timestamp "  - Alarm IP: ${ALARM_IP}"
log_with_timestamp "  - Alarm Port: ${ALARM_PORT}"
log_with_timestamp "  - Password Length: ${PASS_LEN}"
log_with_timestamp "  - Zone Count: ${ZONE_COUNT}"
log_with_timestamp "  - Polling Interval: ${POLLING_INTERVAL_MIN} minutes"
log_with_timestamp "  - MQTT Broker: ${BROKER}:${PORT}"
log_with_timestamp "  - MQTT User: ${USER}"

# Validar configuración crítica
if [[ -z "${ALARM_IP}" || -z "${ALARM_PORT}" || -z "${ALARM_PASS}" ]]; then
    bashio::log.fatal "Missing critical alarm configuration (IP, Port, or Password)"
    exit 1
fi

if [[ -z "${BROKER}" || -z "${PORT}" ]]; then
    bashio::log.fatal "Missing MQTT broker configuration"
    exit 1
fi

# Configurar MQTT
MQTT_OPTS=(-h "$BROKER" -p "$PORT")
if [[ -n "${USER}" ]]; then
    MQTT_OPTS+=(-u "$USER" -P "$PASS")
fi
AVAILABILITY_TOPIC="intelbras/alarm/availability"

# --- PREPARAR DIRECTORIO DE TRABAJO ---
log_with_timestamp "Setting up working directory..."
cd /alarme-intelbras || {
    bashio::log.fatal "Cannot access /alarme-intelbras directory"
    exit 1
}

# Verificar que los binarios existen
if [[ ! -x "./comandar" ]]; then
    bashio::log.fatal "./comandar not found or not executable"
    exit 1
fi

if [[ ! -x "./receptorip" ]]; then
    bashio::log.fatal "./receptorip not found or not executable"
    exit 1
fi

log_with_timestamp "Binaries found and executable"

# --- CREAR ARCHIVO DE CONFIGURACIÓN ---
log_with_timestamp "Creating config.cfg..."
cat > ./config.cfg <<EOF
[geral]
addr = 0.0.0.0
porta_receptor = ${ALARM_PORT}
caddr = ${ALARM_IP}
cport = ${ALARM_PORT}
senha_remota = ${ALARM_PASS}
tamanho_senha = ${PASS_LEN}
EOF

if [[ ! -f "./config.cfg" ]]; then
    bashio::log.fatal "Failed to create config.cfg"
    exit 1
fi

log_with_timestamp "config.cfg created successfully"

# --- PROBAR CONEXIÓN ---
log_with_timestamp "Testing connection to alarm panel..."
COMMAND_TO_RUN="./comandar ${ALARM_IP} ${ALARM_PORT} ${ALARM_PASS} ${PASS_LEN} status"
log_with_timestamp "Executing: ${COMMAND_TO_RUN}"

OUTPUT=$(./comandar "${ALARM_IP}" "${ALARM_PORT}" "${ALARM_PASS}" "${PASS_LEN}" status 2>&1)
EXIT_CODE=$?

log_with_timestamp "Command exit code: ${EXIT_CODE}"

if [[ ${EXIT_CODE} -ne 0 ]]; then
    bashio::log.error "Connection test failed with exit code ${EXIT_CODE}"
    bashio::log.error "Output: ${OUTPUT}"
    bashio::log.fatal "Cannot connect to alarm panel. Check configuration."
    exit 1
fi

log_with_timestamp "Connection test successful"
log_with_timestamp "Alarm status output: ${OUTPUT}"

# --- PUBLICAR DISPONIBILIDAD INICIAL ---
log_with_timestamp "Publishing initial availability..."
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "online"
if [[ $? -eq 0 ]]; then
    log_with_timestamp "MQTT availability published successfully"
else
    bashio::log.warning "Failed to publish MQTT availability"
fi

# --- FUNCIÓN PARA PROCESAR EVENTOS ---
process_events() {
    log_with_timestamp "Starting event processing..."
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            log_with_timestamp "Event received: $line"
            # Aquí puedes agregar el procesamiento de eventos específicos
        fi
    done
}

# --- EJECUTAR RECEPTORIP EN BUCLE ---
log_with_timestamp "Starting main event receiver loop..."

RESTART_COUNT=0
MAX_RESTARTS=10

while true; do
    log_with_timestamp "Starting receptorip (attempt $((RESTART_COUNT + 1)))..."
    log_with_timestamp "Executing: ./receptorip config.cfg"
    
    # Ejecutar receptorip y procesar su salida
    ./receptorip config.cfg 2>&1 | process_events
    
    EXIT_CODE=$?
    log_with_timestamp "receptorip exited with code: ${EXIT_CODE}"
    
    # Marcar como offline
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "offline" 2>/dev/null || true
    
    RESTART_COUNT=$((RESTART_COUNT + 1))
    
    if [[ ${RESTART_COUNT} -ge ${MAX_RESTARTS} ]]; then
        bashio::log.fatal "receptorip failed ${MAX_RESTARTS} times. Stopping addon."
        exit 1
    fi
    
    log_with_timestamp "receptorip stopped. Restarting in 10 seconds... (${RESTART_COUNT}/${MAX_RESTARTS})"
    sleep 10
    
    # Reset contador si ha pasado tiempo suficiente sin fallos
    if [[ ${RESTART_COUNT} -gt 0 ]] && [[ $(($(date +%s) % 300)) -eq 0 ]]; then
        RESTART_COUNT=0
        log_with_timestamp "Reset restart counter"
    fi
done
