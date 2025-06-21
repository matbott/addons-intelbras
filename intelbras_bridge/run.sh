#!/usr/bin/with-contenv bashio

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

cleanup() {
    log "Shutting down..."
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "offline"
    exit 0
}
trap cleanup SIGTERM SIGINT

log "=== Starting Intelbras MQTT Bridge Add-on ==="

# Config
ALARM_IP=$(bashio::config 'alarm_ip')
ALARM_PORT=$(bashio::config 'alarm_port')
ALARM_PASS=$(bashio::config 'alarm_password')
PASS_LEN=$(bashio::config 'password_length')
ZONE_COUNT=$(bashio::config 'zone_count')
BROKER=$(bashio::config 'mqtt_broker')
PORT=$(bashio::config 'mqtt_port')
USER=$(bashio::config 'mqtt_user')
PASS=$(bashio::config 'mqtt_password')

MQTT_OPTS=(-h "$BROKER" -p "$PORT" -u "$USER" -P "$PASS")
AVAILABILITY_TOPIC="intelbras/alarm/availability"
DEVICE_ID="intelbras_alarm"
DISCOVERY_PREFIX="homeassistant"

log "Config OK - Zones: ${ZONE_COUNT}"

# --- Configuración receptorip (como en el script anterior) ---
log "Updating config.cfg..."
sed -i "s/^addr = .*/addr = 0.0.0.0/" ./config.cfg
sed -i "s/^port = .*/port = ${ALARM_PORT}/" ./config.cfg
sed -i "s/^caddr = .*/caddr = ${ALARM_IP}/" ./config.cfg
sed -i "s/^cport = .*/cport = ${ALARM_PORT}/" ./config.cfg
log "config.cfg ready."

# Crear sensores por Discovery
publish_discovery() {
    local name=$1
    local object_id=$2
    local uid=$3
    local device_class=$4
    local force_class=$5
    local expire=${6:-}

    # Crear payload JSON de forma más simple
    local payload='{'
    payload+='"name":"'$name'",'
    payload+='"state_topic":"intelbras/alarm/'$uid'",'
    payload+='"unique_id":"'$uid'",'
    
    # Solo agregar device_class si force_class es true y device_class no está vacío
    if [[ "$force_class" == "true" && -n "$device_class" ]]; then
        payload+='"device_class":"'$device_class'",'
    fi
    
    # Solo agregar expire_after si no está vacío
    if [[ -n "$expire" ]]; then
        payload+='"expire_after":'$expire','
    fi
    
    payload+='"availability_topic":"intelbras/alarm/availability",'
    payload+='"device":{'
    payload+='"identifiers":["'$DEVICE_ID'"],'
    payload+='"name":"Intelbras Alarm",'
    payload+='"model":"AMT-8000",'
    payload+='"manufacturer":"Intelbras"'
    payload+='}}'

    mosquitto_pub "${MQTT_OPTS[@]}" -r \
        -t "${DISCOVERY_PREFIX}/binary_sensor/${DEVICE_ID}/${uid}/config" \
        -m "${payload}"
}

# Alarm state
publish_discovery "Alarm State" "alarm_state" "alarm_state" "" true
# Alarm sounding
publish_discovery "Alarm Sounding" "alarm_sounding" "alarm_sounding" "safety" true
# Panic
publish_discovery "Panic" "panic" "panic" "safety" true
# Zonas
for i in $(seq 1 "$ZONE_COUNT"); do
    publish_discovery "Zone $i" "zone_${i}" "zone_${i}" "opening" true
done

# Publicar estados iniciales
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "$AVAILABILITY_TOPIC" -m "online"
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/alarm_state" -m "disarmed"
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/alarm_sounding" -m "off"
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/panic" -m "off"
for i in $(seq 1 "$ZONE_COUNT"); do
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${i}" -m "off"
done

# Zonas activas
declare -A ACTIVE_ZONES=()
panic_timer_pid=""

handle_event_line() {
    local line="$1"

    if [[ "$line" == *"Ativacao remota app P1"* ]]; then
        log "Alarm armed"
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/alarm_state" -m "armed"

    elif [[ "$line" == *"Desativacao remota app P1"* ]]; then
        log "Alarm disarmed"
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/alarm_state" -m "disarmed"

    elif [[ "$line" =~ Disparo\ de\ zona\ ([0-9]+) ]]; then
        local zone="${BASH_REMATCH[1]}"
        log "Zone $zone triggered"
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${zone}" -m "on"
        ACTIVE_ZONES["$zone"]=1
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/alarm_sounding" -m "on"

    elif [[ "$line" =~ Restauracao\ de\ zona\ ([0-9]+) ]]; then
        local zone="${BASH_REMATCH[1]}"
        log "Zone $zone restored"
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${zone}" -m "off"
        unset ACTIVE_ZONES["$zone"]

        if [[ ${#ACTIVE_ZONES[@]} -eq 0 ]]; then
            mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/alarm_sounding" -m "off"
        fi

    elif [[ "$line" == *"Panico silencioso"* ]]; then
        log "Panic triggered"
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/panic" -m "on"
        (sleep 30 && mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/panic" -m "off") &
    fi
}

log "Starting receptorip..."
# No cambiar de directorio, mantener como en el script anterior
chmod +x receptorip

./receptorip config.cfg 2>&1 | while read -r line; do
    if [[ "$line" == *"Event:"* ]]; then
        clean_line="${line#*Event: }"
        log "Event: $clean_line"
        handle_event_line "$clean_line"
    fi
done
