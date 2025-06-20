#!/usr/bin/with-contenv bashio

bashio::log.info "--- Starting Intelbras MQTT Bridge Add-on v3.0 (Final) ---"

# --- FASE 1: LEER Y PREPARAR CONFIGURACIÓN ---
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
MQTT_OPTS=(-h "$BROKER" -p "$PORT" -u "$USER" -P "$PASS")
AVAILABILITY_TOPIC="intelbras/alarm/availability"

# --- FASE 2: CREAR ARCHIVOS DE CONFIGURACIÓN Y VERIFICAR CONEXIÓN ---
bashio::log.info "Setting up working directory and config files..."
# Nos movemos al directorio de trabajo correcto desde el principio
cd /alarme-intelbras

# Creamos el config.cfg AHORA, para que 'comandar' y 'receptorip' lo encuentren
cat > ./config.cfg <<EOF
[geral]
addr = 0.0.0.0
porta_receptor = ${ALARM_PORT}
caddr = ${ALARM_IP}
cport = ${ALARM_PORT}
senha_remota = ${ALARM_PASS}
tamanho_senha = ${PASS_LEN}
EOF
bashio::log.info "config.cfg created."

# Ahora sí, probamos la conexión. 'comandar' ya encontrará su config.
bashio::log.info "Testing connection and getting initial status from alarm panel at ${ALARM_IP}..."
OUTPUT=$(./comandar "${ALARM_IP}" "${ALARM_PORT}" "${ALARM_PASS}" "${PASS_LEN}" status)
EXIT_CODE=$?

if [ ${EXIT_CODE} -ne 0 ]; then
  bashio::log.fatal "Connection to alarm panel failed. Please check IP, Port, and Password. The Add-on will not start."
  exit 1
fi
bashio::log.info "Connection to alarm panel verified successfully."

# --- FASE 3: PUBLICAR ESTADO INICIAL Y REGISTRAR ENTIDADES ---
bashio::log.info "Publishing initial status to MQTT..."
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "online"
STATUS_BLOCK=$(echo "${OUTPUT}" | sed -n '/\*\*\*\*\*\*\*\*\*\*\*/,/\*\*\*\*\*\*\*\*\*\*\*/p')
if echo "${STATUS_BLOCK}" | grep -q "Desarmado"; then
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "disarmed"
elif echo "${STATUS_BLOCK}" | grep -q "Armado"; then
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "armed_away"
fi
OPEN_ZONES=$(echo "${STATUS_BLOCK}" | grep "Zonas abertas:" | sed 's/Zonas abertas: *//')
for i in $(seq 1 "${ZONE_COUNT}"); do
    if echo "${OPEN_ZONES}" | grep -q -w "${i}"; then
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/zone/${i}/state" -m "ON"
    else
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/zone/${i}/state" -m "OFF"
    fi
done
bashio::log.info "Initial status published."

bashio::log.info "Registering entities in Home Assistant via MQTT Discovery..."
DEVICE_JSON="{\"identifiers\": [\"intelbras_amt8000_bridge\"], \"name\": \"Intelbras Alarm\", \"manufacturer\": \"Intelbras\", \"model\": \"AMT-8000\"}"
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "homeassistant/alarm_control_panel/intelbras_amt8000/alarm/config" \
  -m "{\"name\": \"Alarm Panel\", \"unique_id\": \"intelbras_alarm_panel\", \"availability_topic\": \"${AVAILABILITY_TOPIC}\", \"payload_available\": \"online\", \"payload_not_available\": \"offline\", \"state_topic\": \"intelbras/alarm/state\", \"command_topic\": \"intelbras/alarm/command\", \"command_template\": \"{\\\"action\\\": \\\"{{ action }}\\\", \\\"code\\\": \\\"{{ code }}\\\"}\", \"code_arm_required\": false, \"device\": ${DEVICE_JSON}}"
for i in $(seq 1 "${ZONE_COUNT}"); do
  ZONE_NAME=$(bashio::config "zone_names[$(($i-1))]")
  [[ -z "${ZONE_NAME}" || "${ZONE_NAME}" == "null" ]] && ZONE_NAME="Zone ${i}"
  ZONE_TYPE=$(bashio::config "zone_types[$(($i-1))]")
  [[ -z "${ZONE_TYPE}" || "${ZONE_TYPE}" == "null" ]] && ZONE_TYPE="motion"
  mosquitto_pub "${MQTT_OPTS[@]}" -r -t "homeassistant/binary_sensor/intelbras_amt8000/zone_${i}/config" \
    -m "{\"name\": \"${ZONE_NAME}\", \"unique_id\": \"intelbras_zone_${i}\", \"availability_topic\": \"${AVAILABILITY_TOPIC}\", \"payload_available\": \"online\", \"payload_not_available\": \"offline\", \"state_topic\": \"intelbras/zone/${i}/state\", \"payload_on\": \"ON\", \"payload_off\": \"OFF\", \"device_class\": \"${ZONE_TYPE}\", \"device\": ${DEVICE_JSON}}"
done
bashio::log.info "Entity registration complete."

# --- FASE 4: DEFINICIÓN DE FUNCIONES ---
function poll_and_update_status() {
    bashio::log.info "(Polling) Querying alarm panel for full status..."
    STATUS_OUTPUT=$(./comandar "${ALARM_IP}" "${ALARM_PORT}" "${ALARM_PASS}" "${PASS_LEN}" status)
    EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        bashio::log.warning "Polling failed."
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "offline"
        return
    fi
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "online"
    STATUS_BLOCK=$(echo "${STATUS_OUTPUT}" | sed -n '/\*\*\*\*\*\*\*\*\*\*\*/,/\*\*\*\*\*\*\*\*\*\*\*/p')
    # ... (resto del parseo)
}
function process_event_stream() {
    while read -r event_line; do
        # ... (código de la función sin cambios)
    done
}

# --- FASE 5: INICIAR PROCESOS EN SEGUNDO PLANO Y BUCLE PRINCIPAL ---
bashio::log.info "Starting background processes and main event loop..."
if [[ ${POLLING_INTERVAL_MIN} -gt 0 ]]; then
    (
        sleep 10 
        while true; do
            poll_and_update_status
            sleep $((POLLING_INTERVAL_MIN * 60))
        done
    ) &
fi
(
    mosquitto_sub "${MQTT_OPTS[@]}" -t "intelbras/alarm/command" | while read -r msg; do
        # ... (código del listener de comandos sin cambios)
    done
) &

bashio::log.info "Starting Intelbras event receiver. Add-on is now operational."
while true; do
    ./receptorip config.cfg | process_event_stream
    bashio::log.warning "Event receiver stopped. Reconnecting in 30 seconds..."
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "offline"
    sleep 30
done
