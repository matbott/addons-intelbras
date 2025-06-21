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

trap cleanup SIGTERM SIGINT

log_with_timestamp "=== Starting Intelbras MQTT Bridge Add-on ==="

# --- CARGAR CONFIGURACIÓN ---
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

ZONE_NAMES=$(bashio::config 'zone_names' || echo "[]")
ZONE_TYPES=$(bashio::config 'zone_types' || echo "[]")

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
log_with_timestamp "  - Host Network: enabled"

if [[ -z "${ALARM_IP}" || -z "${ALARM_PORT}" || -z "${ALARM_PASS}" ]]; then
    bashio::log.fatal "Missing critical alarm configuration"
    exit 1
fi
if [[ -z "${BROKER}" || -z "${PORT}" ]]; then
    bashio::log.fatal "Missing MQTT broker configuration"
    exit 1
fi

MQTT_OPTS=(-h "$BROKER" -p "$PORT")
[[ -n "${USER}" ]] && MQTT_OPTS+=(-u "$USER" -P "$PASS")
AVAILABILITY_TOPIC="intelbras/alarm/availability"

log_with_timestamp "Checking current directory: $(pwd)"

if [[ "$(pwd)" != "/alarme-intelbras" ]]; then
    cd /alarme-intelbras || {
        bashio::log.fatal "Cannot access /alarme-intelbras"
        exit 1
    }
fi

chmod +x ./comandar ./receptorip
ls -la ./comandar ./receptorip

log_with_timestamp "Backing up and updating config.cfg..."
cp ./config.cfg ./config.cfg.backup
sed -i "s/^addr = .*/addr = 0.0.0.0/" ./config.cfg
sed -i "s/^port = .*/port = ${ALARM_PORT}/" ./config.cfg
sed -i "s/^caddr = .*/caddr = ${ALARM_IP}/" ./config.cfg
sed -i "s/^cport = .*/cport = ${ALARM_PORT}/" ./config.cfg
sed -i "s/^senha = .*/senha = ${ALARM_PASS}/" ./config.cfg
sed -i "s/^tamanho = .*/tamanho = ${PASS_LEN}/" ./config.cfg
cat ./config.cfg | sed "s/senha = .*/senha = [HIDDEN]/"

log_with_timestamp "Testing connection to alarm..."
./comandar "${ALARM_IP}" "${ALARM_PORT}" "${ALARM_PASS}" "${PASS_LEN}" status > status_test.log 2>&1
EXIT_CODE=$?
log_with_timestamp "Command exit code: ${EXIT_CODE}"
[[ ${EXIT_CODE} -ne 0 ]] && {
    bashio::log.fatal "Cannot connect to alarm panel"
    cat status_test.log
    exit 1
}
log_with_timestamp "Connection test successful"
log_with_timestamp "Alarm status output: $(head -n 3 status_test.log)"

log_with_timestamp "Publishing initial availability..."
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "online"

# --- NUEVA LÓGICA DE ESTADO DE ALARMA ---
ALARM_STATE="unknown"
publish_alarm_state() {
    NEW_STATE=$1
    if [[ "$NEW_STATE" != "$ALARM_STATE" ]]; then
        ALARM_STATE="$NEW_STATE"
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "$ALARM_STATE"
        log_with_timestamp "Alarm state changed → $ALARM_STATE"
    fi
}

# --- LOOP PRINCIPAL receptorip ---
log_with_timestamp "Starting main event receiver loop..."
RESTART_COUNT=0
MAX_RESTARTS=10

while true; do
    log_with_timestamp "Starting receptorip (attempt $((RESTART_COUNT + 1)))..."
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "online"

    ./receptorip config.cfg 2>&1 | while IFS= read -r line; do
        [[ -n "$line" ]] && log_with_timestamp "Event received: $line"

        if echo "$line" | grep -q "Ativacao remota app"; then
            publish_alarm_state "armed"
        elif echo "$line" | grep -q "Desativacao remota app"; then
            publish_alarm_state "disarmed"
        fi
    done

    EXIT_CODE=${PIPESTATUS[0]}
    log_with_timestamp "receptorip exited with code: ${EXIT_CODE}"

    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "offline"
    RESTART_COUNT=$((RESTART_COUNT + 1))

    if [[ ${RESTART_COUNT} -ge ${MAX_RESTARTS} ]]; then
        bashio::log.fatal "receptorip failed ${MAX_RESTARTS} times. Stopping addon."
        exit 1
    fi

    SLEEP_TIME=$((10 + RESTART_COUNT * 5))
    log_with_timestamp "receptorip stopped. Restarting in ${SLEEP_TIME} seconds..."
    sleep ${SLEEP_TIME}
done
