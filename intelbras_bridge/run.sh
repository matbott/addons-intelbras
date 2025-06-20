#!/usr/bin/with-contenv bashio

bashio::log.info "--- Starting Intelbras MQTT Bridge Add-on v3.0 (Final) ---"

# --- FASE 1: LEER CONFIGURACIÓN ---
ALARM_IP=$(bashio::config 'alarm_ip')
ALARM_PORT=$(bashio::config 'alarm_port')
ALARM_PASS=$(bashio::config 'alarm_password')
PASS_LEN=$(bashio::config 'password_length')
ZONE_COUNT=$(bashio::config 'zone_count')
POLLING_INTERVAL_MIN=$(bashio::config 'polling_interval_minutes')

# --- FASE 2: VERIFICAR CONEXIÓN Y OBTENER ESTADO INICIAL ---
bashio::log.info "Testing connection and getting initial status from alarm panel at ${ALARM_IP}..."
OUTPUT=$(/alarme-intelbras/comandar "${ALARM_IP}" "${ALARM_PORT}" "${ALARM_PASS}" "${PASS_LEN}" status)
EXIT_CODE=$?

if [ ${EXIT_CODE} -ne 0 ]; then
  bashio::log.fatal "Connection to alarm panel failed. Please check IP, Port, and Password. The Add-on will not start."
  exit 1
fi
bashio::log.info "Connection to alarm panel verified successfully."

# --- FASE 3: CONFIGURACIÓN DE MQTT ---
BROKER=$(bashio::config 'mqtt_broker')
PORT=$(bashio::config 'mqtt_port')
USER=$(bashio::config 'mqtt_user')
PASS=$(bashio::config 'mqtt_password')
MQTT_OPTS=(-h "$BROKER" -p "$PORT" -u "$USER" -P "$PASS")
AVAILABILITY_TOPIC="intelbras/alarm/availability"

# --- FASE 3.1: PUBLICAR ESTADO INICIAL (USANDO LA RESPUESTA DE LA FASE 2) ---
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


# --- FASE 3.2: REGISTRAR ENTIDADES EN HOME ASSISTANT ---
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

# --- FASE 4: FUNCIONES PRINCIPALES ---
function poll_and_update_status() {
    bashio::log.info "(Polling) Querying alarm panel for full status..."
    # Se usa ./comandar porque ya estaremos en el directorio correcto
    STATUS_OUTPUT=$(./comandar "${ALARM_IP}" "${ALARM_PORT}" "${ALARM_PASS}" "${PASS_LEN}" status)
    EXIT_CODE=$?

    if [ $EXIT_CODE -ne 0 ]; then
        bashio::log.warning "Polling failed. Could not get status from alarm panel."
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "offline"
        return
    fi
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "online"
    STATUS_BLOCK=$(echo "${STATUS_OUTPUT}" | sed -n '/\*\*\*\*\*\*\*\*\*\*\*/,/\*\*\*\*\*\*\*\*\*\*\*/p')
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
    bashio::log.info "(Polling) Status update complete."
}

function process_event_stream() {
    while read -r event_line; do
        bashio::log.info "EVENT: ${event_line}"
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "online"
        message=$(echo "${event_line}" | sed -E 's/^[0-9]{4}(-[0-9]{2}){2} ([0-9]{2}:){2}[0-9]{2} [0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+ //')
        case "${message}" in
            "Ativacao remota app P"*) PAYLOAD="armed_away";;
            "Desativacao remota app P"*) PAYLOAD="disarmed";;
            "Panico silencioso"*) PAYLOAD="triggered";;
            "Disparo de zona "*) 
                PAYLOAD="triggered"
                ZONE_NUM=$(echo "${message}" | grep -o -E '[0-9]+')
                mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/zone/${ZONE_NUM}/state" -m "ON"
                ;;
            "Restauracao de zona "*)
                ZONE_NUM=$(echo "${message}" | grep -o -E '[0-9]+')
                mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/zone/${ZONE_NUM}/state" -m "OFF"
                ;;
        esac
        if [[ -n "${PAYLOAD}" ]]; then
            mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "${PAYLOAD}"
        fi
    done
}

# --- FASE 5: INICIAR OPERACIÓN ---

# Nos movemos al directorio de trabajo correcto
cd /alarme-intelbras

# Iniciar sondeo periódico en segundo plano (si está configurado)
if [[ ${POLLING_INTERVAL_MIN} -gt 0 ]]; then
    (
        # Esperar un poco antes de empezar el sondeo para no colisionar
        sleep 10 
        while true; do
            poll_and_update_status
            sleep $((POLLING_INTERVAL_MIN * 60))
        done
    ) &
fi

# Iniciar escucha de comandos de Home Assistant en segundo plano
(
    mosquitto_sub "${MQTT_OPTS[@]}" -t "intelbras/alarm/command" | while read -r msg; do
        bashio::log.info "COMMAND: Received from Home Assistant: ${msg}"
        ACTION=$(echo "${msg}" | jq -r '.action')
        case ${ACTION} in
            "ARM_AWAY")
                ./comandar "${ALARM_IP}" "${ALARM_PORT}" "${ALARM_PASS}" "${PASS_LEN}" "ativar"
                ;;
            "DISARM")
                ./comandar "${ALARM_IP}" "${ALARM_PORT}" "${ALARM_PASS}" "${PASS_LEN}" "desativar"
                ;;
        esac
    done
) &

bashio::log.info "Starting Intelbras event receiver. Add-on is now operational."
cat > ./config.cfg <<EOF
[geral]
addr = 0.0.0.0
porta_receptor = ${ALARM_PORT}
caddr = ${ALARM_IP}
cport = ${ALARM_PORT}
senha_remota = ${ALARM_PASS}
tamanho_senha = ${PASS_LEN}
EOF

# Bucle principal para mantener el receptor de eventos corriendo
while true; do
    ./receptorip config.cfg | process_event_stream
    bashio::log.warning "Event receiver stopped. Reconnecting in 30 seconds..."
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "offline"
    sleep 30
done
