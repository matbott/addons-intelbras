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

# Cargar configuración de zonas
ZONE_NAMES=$(bashio::config 'zone_names' || echo "[]")
ZONE_TYPES=$(bashio::config 'zone_types' || echo "[]")

# Mostrar configuración (sin mostrar passwords completas)
log_with_timestamp "Configuration loaded:"
log_with_timestamp "  - Alarm IP: ${ALARM_IP}"
log_with_timestamp "  - Alarm Port: ${ALARM_PORT}"
log_with_timestamp "  - Password Length: ${PASS_LEN}"
log_with_timestamp "  - Zone Count: ${ZONE_COUNT}"
log_with_timestamp "  - Zone Names: ${ZONE_NAMES}"
log_with_timestamp "  - Zone Types: ${ZONE_TYPES}"
log_with_timestamp "  - Polling Interval: ${POLLING_INTERVAL_MIN} minutes"
log_with_timestamp "  - MQTT Broker: ${BROKER}:${PORT}"
log_with_timestamp "  - MQTT User: ${USER}"
log_with_timestamp "  - Host Network: enabled (port 9009 available)"

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

# --- VERIFICAR DIRECTORIO DE TRABAJO ---
log_with_timestamp "Current working directory: $(pwd)"
log_with_timestamp "Contents of current directory:"
ls -la

# El Dockerfile ya establece WORKDIR en /alarme-intelbras, así que ya deberíamos estar ahí
if [[ "$(pwd)" != "/alarme-intelbras" ]]; then
    log_with_timestamp "Not in expected directory, changing to /alarme-intelbras"
    cd /alarme-intelbras || {
        bashio::log.fatal "Cannot access /alarme-intelbras directory"
        exit 1
    }
fi

# Verificar que los binarios existen y tienen permisos
log_with_timestamp "Checking binaries..."
if [[ ! -f "./comandar" ]]; then
    bashio::log.fatal "./comandar not found"
    exit 1
fi

if [[ ! -x "./comandar" ]]; then
    log_with_timestamp "comandar found but not executable, fixing permissions..."
    chmod +x ./comandar
fi

if [[ ! -f "./receptorip" ]]; then
    bashio::log.fatal "./receptorip not found"
    exit 1
fi

if [[ ! -x "./receptorip" ]]; then
    log_with_timestamp "receptorip found but not executable, fixing permissions..."
    chmod +x ./receptorip
fi

log_with_timestamp "Binaries verified:"
ls -la ./comandar ./receptorip

# --- VERIFICAR Y ACTUALIZAR ARCHIVO DE CONFIGURACIÓN ---
log_with_timestamp "Checking existing config.cfg..."

if [[ ! -f "./config.cfg" ]]; then
    bashio::log.fatal "config.cfg not found in repository"
    exit 1
fi

log_with_timestamp "Original config.cfg found, backing up..."
cp ./config.cfg ./config.cfg.backup

log_with_timestamp "Updating config.cfg with addon parameters..."

# Actualizar solo los parámetros necesarios usando sed
sed -i "s/^addr = .*/addr = 0.0.0.0/" ./config.cfg
sed -i "s/^port = .*/port = ${ALARM_PORT}/" ./config.cfg
sed -i "s/^caddr = .*/caddr = ${ALARM_IP}/" ./config.cfg
sed -i "s/^cport = .*/cport = ${ALARM_PORT}/" ./config.cfg
sed -i "s/^senha = .*/senha = ${ALARM_PASS}/" ./config.cfg
sed -i "s/^tamanho = .*/tamanho = ${PASS_LEN}/" ./config.cfg

log_with_timestamp "config.cfg updated successfully"
log_with_timestamp "Updated config.cfg contents (passwords hidden):"
cat ./config.cfg | sed "s/senha = .*/senha = [HIDDEN]/"

# --- PROBAR CONEXIÓN ---
log_with_timestamp "Testing connection to alarm panel..."
COMMAND_TO_RUN="./comandar ${ALARM_IP} ${ALARM_PORT} [HIDDEN_PASS] ${PASS_LEN} status"
log_with_timestamp "Executing: ${COMMAND_TO_RUN}"

# Primero verificar que el comando existe y se puede ejecutar
log_with_timestamp "Testing binary execution..."
if ! ./comandar --help >/dev/null 2>&1; then
    log_with_timestamp "Testing basic execution of comandar..."
    ./comandar 2>&1 | head -5 || true
fi

log_with_timestamp "Attempting connection to alarm..."
OUTPUT=$(timeout 30 ./comandar "${ALARM_IP}" "${ALARM_PORT}" "${ALARM_PASS}" "${PASS_LEN}" status 2>&1)
EXIT_CODE=$?

log_with_timestamp "Command exit code: ${EXIT_CODE}"

if [[ ${EXIT_CODE} -eq 124 ]]; then
    bashio::log.error "Connection test timed out after 30 seconds"
    bashio::log.fatal "Alarm panel not responding. Check network connectivity."
    exit 1
elif [[ ${EXIT_CODE} -ne 0 ]]; then
    bashio::log.error "Connection test failed with exit code ${EXIT_CODE}"
    bashio::log.error "Output: ${OUTPUT}"
    bashio::log.fatal "Cannot connect to alarm panel. Check configuration."
    exit 1
fi

log_with_timestamp "Connection test successful"
log_with_timestamp "Alarm status output (first 3 lines): $(echo "${OUTPUT}" | head -3)"

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
    
    # Marcar como online antes de iniciar
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "online" 2>/dev/null || true
    
    # Ejecutar receptorip con timeout y procesar su salida
    timeout 300 ./receptorip config.cfg 2>&1 | process_events
    
    EXIT_CODE=$?
    
    if [[ ${EXIT_CODE} -eq 124 ]]; then
        log_with_timestamp "receptorip timed out after 5 minutes, restarting..."
    else
        log_with_timestamp "receptorip exited with code: ${EXIT_CODE}"
    fi
    
    # Marcar como offline
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "offline" 2>/dev/null || true
    
    RESTART_COUNT=$((RESTART_COUNT + 1))
    
    if [[ ${RESTART_COUNT} -ge ${MAX_RESTARTS} ]]; then
        bashio::log.fatal "receptorip failed ${MAX_RESTARTS} times. Stopping addon."
        exit 1
    fi
    
    SLEEP_TIME=$((10 + RESTART_COUNT * 5)) # Backoff incremental
    log_with_timestamp "receptorip stopped. Restarting in ${SLEEP_TIME} seconds... (${RESTART_COUNT}/${MAX_RESTARTS})"
    sleep ${SLEEP_TIME}
    
    # Reset contador después de 30 minutos sin fallos
    if [[ ${RESTART_COUNT} -gt 0 ]] && [[ $(($(date +%s) % 1800)) -eq 0 ]]; then
        RESTART_COUNT=0
        log_with_timestamp "Reset restart counter after stable period"
    fi
done
