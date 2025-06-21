#!/usr/bin/with-contenv bashio

# Función para registrar logs con fecha y hora
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Función de limpieza al detener el add-on
cleanup() {
    log "Shutting down addon..."
    # Publica el estado 'offline' en el topic de disponibilidad
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "offline" || true
    exit 0
}
# Atrapa las señales de terminación para ejecutar la limpieza
trap cleanup SIGTERM SIGINT

log "=== Starting Intelbras MQTT Bridge Add-on ==="

# --- Configuración del Add-on ---
ALARM_PORT=$(bashio::config 'alarm_port')
ALARM_IP=$(bashio::config 'alarm_ip')
ZONE_COUNT=$(bashio::config 'zone_count')
BROKER=$(bashio::config 'mqtt_broker')
PORT=$(bashio::config 'mqtt_port')
USER=$(bashio::config 'mqtt_user')
PASS=$(bashio::config 'mqtt_password')

# Opciones base para mosquitto_pub
MQTT_OPTS=(-h "$BROKER" -p "$PORT")
# Añade usuario y contraseña si están definidos
[[ -n "$USER" ]] && MQTT_OPTS+=(-u "$USER" -P "$PASS")

# --- Constantes MQTT ---
AVAILABILITY_TOPIC="intelbras/alarm/availability"
DEVICE_ID="intelbras_alarm"
DISCOVERY_PREFIX="homeassistant"

log "MQTT broker: $BROKER:$PORT, user: $USER"
log "Alarm IP: $ALARM_IP, port: $ALARM_PORT"
log "Zone count: $ZONE_COUNT"

# --- Función de Discovery de Home Assistant (Modificada) ---
# Se añaden payload_on y payload_off como argumentos
publish_discovery() {
    local name=$1
    local uid=$2
    local device_class=$3
    local payload_on=$4   # Payload para el estado ON
    local payload_off=$5  # Payload para el estado OFF
    
    local state_topic="intelbras/alarm/${uid}"
    
    # Construcción del payload JSON
    local payload='{'
    payload+='"name":"'$name'",'
    payload+='"state_topic":"'$state_topic'",'
    payload+='"unique_id":"'$uid'",'
    
    # Añade la clase de dispositivo si se especifica
    if [[ -n "$device_class" ]]; then
        payload+='"device_class":"'$device_class'",'
    fi
    
    # --- LA CORRECCIÓN CLAVE ESTÁ AQUÍ ---
    # Especifica los payloads para ON y OFF
    payload+='"payload_on":"'$payload_on'",'
    payload+='"payload_off":"'$payload_off'",'
    
    payload+='"availability_topic":"'$AVAILABILITY_TOPIC'",'
    payload+='"device":{'
    payload+='"identifiers":["'$DEVICE_ID'"],'
    payload+='"name":"Intelbras Alarm",'
    payload+='"model":"AMT-8000",'
    payload+='"manufacturer":"Intelbras"'
    payload+='}}'

    # Publica el mensaje de discovery con retención
    mosquitto_pub "${MQTT_OPTS[@]}" -r \
        -t "${DISCOVERY_PREFIX}/binary_sensor/${DEVICE_ID}/${uid}/config" \
        -m "${payload}"
}

# --- Crear dispositivos para Home Assistant Discovery ---
log "Setting up Home Assistant discovery..."
#                                   NAME              UID         DEVICE_CLASS    PAYLOAD_ON      PAYLOAD_OFF
publish_discovery "Alarm State"     "state"           "lock"          "armed"         "disarmed"
publish_discovery "Alarm Sounding"  "sounding"        "safety"        "on"            "off"
publish_discovery "Panic"           "panic"           "safety"        "on"            "off"

# Crear zonas
for i in $(seq 1 "$ZONE_COUNT"); do
    publish_discovery "Zone $i" "zone_${i}" "opening" "on" "off"
done

# --- Configuración de receptorip ---
log "Updating config.cfg..."
sed -i "s/^addr = .*/addr = 0.0.0.0/" ./config.cfg
sed -i "s/^port = .*/port = ${ALARM_PORT}/" ./config.cfg
sed -i "s/^caddr = .*/caddr = ${ALARM_IP}/" ./config.cfg
sed -i "s/^cport = .*/cport = ${ALARM_PORT}/" ./config.cfg
log "config.cfg ready."

# --- Publicar estados iniciales ---
log "Publishing availability and initial states..."
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "$AVAILABILITY_TOPIC" -m "online"
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "disarmed"
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/sounding" -m "off"
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/panic" -m "off"

for i in $(seq 1 "$ZONE_COUNT"); do
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${i}" -m "off"
done

# --- Variable para seguimiento de zonas activas ---
declare -A ACTIVE_ZONES=()

# --- Ejecutar receptorip y procesar eventos ---
log "Starting receptorip..."
./receptorip config.cfg 2>&1 | while IFS= read -r line; do
    # Ignorar líneas vacías
    [[ -z "$line" ]] && continue
    log "Event: $line"
    
    # Eventos de armado/desarmado
    if echo "$line" | grep -q "Ativacao remota app"; then
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "armed"
        log "Alarm state set to: armed"
        
    elif echo "$line" | grep -q "Desativacao remota app"; then
        mosquitto_pub "${MQTT_OPTOPS[@]}" -r -t "intelbras/alarm/state" -m "disarmed"
        log "Alarm state set to: disarmed"
        
    # Eventos de zonas (disparo)
    elif echo "$line" | grep -q "Disparo de zona"; then
        if [[ "$line" =~ Disparo\ de\ zona\ ([0-9]+) ]]; then
            local zone="${BASH_REMATCH[1]}"
            log "Zone $zone triggered"
            mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${zone}" -m "on"
            ACTIVE_ZONES["$zone"]=1
            mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/sounding" -m "on"
        fi
        
    # Eventos de zonas (restauración)
    elif echo "$line" | grep -q "Restauracao de zona"; then
        if [[ "$line" =~ Restauracao\ de\ zona\ ([0-9]+) ]]; then
            local zone="${BASH_REMATCH[1]}"
            log "Zone $zone restored"
            mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${zone}" -m "off"
            unset ACTIVE_ZONES["$zone"]
            
            # Si no quedan zonas activas disparadas, apagar la sirena
            if [[ ${#ACTIVE_ZONES[@]} -eq 0 ]]; then
                log "All zones restored. Turning off sounding state."
                mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/sounding" -m "off"
            fi
        fi
        
    # Evento de pánico
    elif echo "$line" | grep -q "Panico silencioso"; then
        log "Panic triggered"
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/panic" -m "on"
        # Auto-resetea el estado de pánico después de 30 segundos en segundo plano
        (sleep 30 && mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/panic" -m "off" &)
    fi
done

# Llamada final a cleanup en caso de que el bucle termine
cleanup
