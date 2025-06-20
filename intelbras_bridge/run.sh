#!/usr/bin/with-contenv bashio

bashio::log.info "--- Starting Intelbras MQTT Bridge Add-on v3.0 (Final) ---"

# --- FASE 1: LEER Y VALIDAR CONFIGURACIÓN ---
ALARM_IP=$(bashio::config 'alarm_ip')
ALARM_PORT=$(bashio::config 'alarm_port')
ALARM_PASS=$(bashio::config 'alarm_password')
PASS_LEN=$(bashio::config 'password_length')
ZONE_COUNT=$(bashio::config 'zone_count')
POLLING_INTERVAL_MIN=$(bashio::config 'polling_interval_minutes')

echo "DEBUG - Variables recibidas:"
echo "ALARM_IP=$(bashio::config 'alarm_ip')"
echo "ALARM_PORT=$(bashio::config 'alarm_port')"
echo "ALARM_PASS=$(bashio::config 'alarm_password')"
echo "PASS_LEN=$(bashio::config 'password_length')"
echo "ZONE_COUNT=$(bashio::config 'zone_count')"
echo "POLLING_INTERVAL_MIN=$(bashio::config 'polling_interval_minutes')"

# --- FASE 2: VALIDAR Y VERIFICAR CONEXIÓN (CORREGIDO) ---

# Primero, verificar que las variables requeridas no estén vacías
if bashio::var.is_empty "${ALARM_IP}" || bashio::var.is_empty "${ALARM_PASS}"; then
  bashio::log.fatal "Alarm Panel IP Address and Password are required. Please set them and restart."
  exit 1
fi

# Ejecutar el comando de prueba UNA SOLA VEZ
bashio::log.info "Testing connection to alarm panel at ${ALARM_IP}..."
OUTPUT=$(/alarme-intelbras/comandar "${ALARM_IP}" "${ALARM_PORT}" "${ALARM_PASS}" "${PASS_LEN}" status)
EXIT_CODE=$?

# Mostrar la salida del debug
echo "DEBUG - Resultado comando: ${EXIT_CODE}"
echo "DEBUG - Salida del comando:"
echo "${OUTPUT}"

# Usar el CÓDIGO DE SALIDA ya guardado para verificar la conexión
if [ ${EXIT_CODE} -ne 0 ]; then
  bashio::log.fatal "Could not connect to the alarm panel. Please check IP, Port, and Password. The Add-on will not start."
  exit 1
fi

# Si llegamos aquí, la conexión fue exitosa
bashio::log.info "Connection to alarm panel verified successfully."


# --- FASE 3: CONFIGURACIÓN DE MQTT Y ENTIDADES ---
MQTT_HOST=$(bashio::services "mqtt" "host")
MQTT_PORT=$(bashio::services "mqtt" "port")
MQTT_USER=$(bashio::services "mqtt" "username")
MQTT_PASS=$(bashio::services "mqtt" "password")
#MQTT_OPTS="-h ${MQTT_HOST} -p ${MQTT_PORT} -u ${MQTT_USER} -P ${MQTT_PASS}"

BROKER=$(bashio::config 'mqtt_broker')
PORT=$(bashio::config 'mqtt_port')
USER=$(bashio::config 'mqtt_user')
PASS=$(bashio::config 'mqtt_password')
MQTT_OPTS=(-h "$BROKER" -p "$PORT" -u "$USER" -P "$PASS")

echo "MQTT_OPTS=(-h "$BROKER" -p "$PORT" -u "$USER" -P "$PASS")"

bashio::log.info "Registering entities in Home Assistant via MQTT Discovery..."
DEVICE_JSON="{\"identifiers\": [\"intelbras_amt8000_bridge\"], \"name\": \"Intelbras Alarm\", \"manufacturer\": \"Intelbras\", \"model\": \"AMT-8000\"}"
AVAILABILITY_TOPIC="intelbras/alarm/availability"

# Registrar el Panel de Alarma Principal
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "homeassistant/alarm_control_panel/intelbras_amt8000/alarm/config" \
  -m "{\"name\": \"Alarm Panel\", \"unique_id\": \"intelbras_alarm_panel\", \"availability_topic\": \"${AVAILABILITY_TOPIC}\", \"payload_available\": \"online\", \"payload_not_available\": \"offline\", \"state_topic\": \"intelbras/alarm/state\", \"command_topic\": \"intelbras/alarm/command\", \"command_template\": \"{\\\"action\\\": \\\"{{ action }}\\\", \\\"code\\\": \\\"{{ code }}\\\"}\", \"code_arm_required\": false, \"device\": ${DEVICE_JSON}}"

# Registrar los sensores de zona
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

# Función para sondear la central y actualizar estados
function poll_and_update_status() {
    bashio::log.info "(Polling) Querying alarm panel for full status..."
    STATUS_OUTPUT=$(/alarme-intelbras/comandar "${ALARM_IP}" "${ALARM_PORT}" "${ALARM_PASS}" "${PASS_LEN}" status)
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

# Función para procesar eventos en tiempo real
function process_event_stream() {
    while read -r event_line; do
        bashio::log.info "EVENT: ${event_line}"
        mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "online"
        message=$(echo "${event_line}" | sed -E 's/^[0-9]{4}(-[0-9]{2}){2} ([0-9]{2}:){2}[0-9]{2} [0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+ //')

        TOPIC=""
        PAYLOAD=""

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

# !! CAMBIO IMPORTANTE: Nos movemos al directorio de trabajo correcto !!
cd /alarme-intelbras

# AHORA SE EJECUTA LA FUNCIÓN POR PRIMERA VEZ
poll_and_update_status

if [[ ${POLLING_INTERVAL_MIN} -gt 0 ]]; then
    (
        while true; do
            sleep $((POLLING_INTERVAL_MIN * 60))
            poll_and_update_status
        done
    ) &
fi

(
    mosquitto_sub "${MQTT_OPTS[@]}" -t "intelbras/alarm/command" | while read -r msg; do
        bashio::log.info "COMMAND: Received from Home Assistant: ${msg}"
        ACTION=$(echo "${msg}" | jq -r '.action')
        case ${ACTION} in
            "ARM_AWAY")
                /alarme-intelbras/comandar "${ALARM_IP}" "${ALARM_PORT}" "${ALARM_PASS}" "${PASS_LEN}" "ativar"
                ;;
            "DISARM")
                /alarme-intelbras/comandar "${ALARM_IP}" "${ALARM_PORT}" "${ALARM_PASS}" "${PASS_LEN}" "desativar"
                ;;
        esac
    done
) &

bashio::log.info "Starting Intelbras event receiver. Add-on is now operational."
cat > /alarme-intelbras/config.cfg <<EOF
[geral]
addr = 0.0.0.0
porta_receptor = ${ALARM_PORT}
caddr = ${ALARM_IP}
cport = ${ALARM_PORT}
senha_remota = ${ALARM_PASS}
tamanho_senha = ${PASS_LEN}
EOF

# Bucle principal para mantener el receptor corriendo y reconectar si falla
while true; do
    cd /alarme-intelbras
    ./receptorip config.cfg | process_event_stream
    bashio::log.warning "Event receiver stopped. Reconnecting in 30 seconds..."
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "offline"
    sleep 30
done
