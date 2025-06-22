#!/usr/bin/with-contenv bashio

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
cleanup() { log "Shutting down..."; mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "offline" || true; exit 0; }
trap cleanup SIGTERM SIGINT

log "=== Starting Intelbras MQTT Bridge Add-on (Discovery Mode v2) ==="

ALARM_PORT=$(bashio::config 'alarm_port')
ALARM_IP=$(bashio::config 'alarm_ip')
ALARM_PASS=$(bashio::config 'alarm_password')
ZONE_COUNT=$(bashio::config 'zone_count')
BROKER=$(bashio::config 'mqtt_broker')
PORT=$(bashio::config 'mqtt_port')
USER=$(bashio::config 'mqtt_user')
PASS=$(bashio::config 'mqtt_password')

MQTT_OPTS=(-h "$BROKER" -p "$PORT")
[[ -n "$USER" ]] && MQTT_OPTS+=(-u "$USER" -P "$PASS")

AVAILABILITY_TOPIC="intelbras/alarm/availability"
DEVICE_ID="intelbras_alarm"
DISCOVERY_PREFIX="homeassistant"

log "MQTT broker: $BROKER:$PORT, user: $USER"
log "Alarm IP: $ALARM_IP, port: $ALARM_PORT, Zone count: $ZONE_COUNT"

# --- Funciones de Discovery (separadas para mayor claridad) ---

publish_binary_sensor_discovery() {
    local name=$1; local uid=$2; local device_class=$3; local payload_on=$4; local payload_off=$5
    local state_topic="intelbras/alarm/${uid}"
    local payload='{'
    payload+='"name":"'$name'",'
    payload+='"state_topic":"'$state_topic'",'
    payload+='"unique_id":"'$uid'",'
    [[ -n "$device_class" ]] && payload+='"device_class":"'$device_class'",'
    payload+='"payload_on":"'$payload_on'",'
    payload+='"payload_off":"'$payload_off'",'
    payload+='"availability_topic":"'$AVAILABILITY_TOPIC'",'
    payload+='"device":{"identifiers":["'$DEVICE_ID'"],"name":"Intelbras Alarm","model":"AMT-8000","manufacturer":"Intelbras"}'
    payload+='}'
    # El topic ahora es /binary_sensor/
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${DISCOVERY_PREFIX}/binary_sensor/${DEVICE_ID}/${uid}/config" -m "${payload}"
}

publish_text_sensor_discovery() {
    local name=$1; local uid=$2; local icon=$3
    local state_topic="intelbras/alarm/${uid}"
    local payload='{'
    payload+='"name":"'$name'",'
    payload+='"state_topic":"'$state_topic'",'
    payload+='"unique_id":"'$uid'",'
    payload+='"icon":"'$icon'",'
    payload+='"availability_topic":"'$AVAILABILITY_TOPIC'",'
    payload+='"device":{"identifiers":["'$DEVICE_ID'"],"name":"Intelbras Alarm","model":"AMT-8000","manufacturer":"Intelbras"}'
    payload+='}'
    # ¡OJO! El topic ahora es /sensor/, no /binary_sensor/
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${DISCOVERY_PREFIX}/sensor/${DEVICE_ID}/${uid}/config" -m "${payload}"
}

log "Setting up Home Assistant discovery..."
# --- CAMBIO 1: Ahora se crean como sensores de texto con iconos personalizados ---
publish_text_sensor_discovery "Estado Alarma" "state" "mdi:shield-lock"
publish_text_sensor_discovery "Sirena" "sounding" "mdi:alarm-bell"

# Los sensores de pánico y zonas siguen siendo binarios, lo cual es correcto
publish_binary_sensor_discovery "Pánico" "panic" "safety" "on" "off"
for i in $(seq 1 "$ZONE_COUNT"); do
    publish_binary_sensor_discovery "Zona $i" "zone_${i}" "opening" "on" "off"
done

log "Generating config.cfg..."
cat > config.cfg << EOF
[receptorip]
; interface de rede e porta do Receptor IP
addr = 0.0.0.0
port = ${ALARM_PORT}
; Centrais cuja conexão aceitaremos - expressão regular
centrais = .*
; Número máximo de centrais conectadas e autenticadas simultâneas
maxconn = 1
; endereço e porta da central de alarme
caddr = ${ALARM_IP}
cport = ${ALARM_PORT}
; senha de acesso remoto (usuário 98) e tamanho em digitos (4 ou 6)
senha = ${ALARM_PASS}
tamanho = ${ZONE_COUNT}
; local de gravação dos arquivos de foto obtidos do IVP-8000 Pet Cam
folder_dlfoto = .
; archivo de log. Informar "None" para desligar
logfile = None
EOF
log "config.cfg ready."

log "Publishing availability and initial states..."
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "$AVAILABILITY_TOPIC" -m "online"
# --- CAMBIO 2: Publicar los nuevos estados de texto iniciales ---
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "Desarmada"
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/sounding" -m "Normal"
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/panic" -m "off"
for i in $(seq 1 "$ZONE_COUNT"); do
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${i}" -m "off"
done

log "Starting receptorip..."
declare -A ACTIVE_ZONES=()
./receptorip config.cfg 2>&1 | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    log "Event: $line"

    # --- CAMBIO 3: Publicar los nuevos textos en los eventos ---
    if echo "$line" | grep -q "Ativacao remota app"; then
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "Armada"
    elif echo "$line" | grep -q "Desativacao remota app"; then
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "Desarmada"
    elif [[ "$line" =~ Disparo\ de\ zona\ ([0-9]+) ]]; then
        local zone="${BASH_REMATCH[1]}"
        ACTIVE_ZONES["$zone"]=1
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${zone}" -m "on"
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/sounding" -m "Disparada" # Nuevo texto
    elif [[ "$line" =~ Restauracao\ de\ zona\ ([0-9]+) ]]; then
        local zone="${BASH_REMATCH[1]}"
        unset ACTIVE_ZONES["$zone"]
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${zone}" -m "off"
        if [[ ${#ACTIVE_ZONES[@]} -eq 0 ]]; then
            mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/sounding" -m "Normal" # Nuevo texto
        fi
    elif echo "$line" | grep -q "Panico silencioso"; then
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/panic" -m "on"
        (sleep 30 && mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/panic" -m "off") &
    fi
done

cleanup
