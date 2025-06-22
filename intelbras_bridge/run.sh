#!/usr/bin/with-contenv bashio

# --- FUNCIONES Y TRAPS (TRAMPAS) ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
# --- TRAMPA DE LIMPIEZA MEJORADA ---
cleanup() {
    log "Encerrando... Deteniendo procesos en segundo plano."
    # Esta línea mata cualquier proceso hijo que quede corriendo para una salida limpia.
    pkill -P $$
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${AVAILABILITY_TOPIC}" -m "offline" || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# --- LECTURA DE CONFIGURACIÓN ---
log "=== Iniciando Intelbras MQTT Bridge Add-on (v3 - Comandos Habilitados) ==="

ALARM_PORT=$(bashio::config 'alarm_port')
ALARM_IP=$(bashio::config 'alarm_ip')
ALARM_PASS=$(bashio::config 'alarm_password')
# --- NUEVO: Leer la longitud de la contraseña desde la configuración ---
PASSWORD_LENGTH=$(bashio::config 'password_length')
ZONE_COUNT=$(bashio::config 'zone_count')
BROKER=$(bashio::config 'mqtt_broker')
PORT=$(bashio::config 'mqtt_port')
USER=$(bashio::config 'mqtt_user')
PASS=$(bashio::config 'mqtt_password')

# --- CONFIGURACIÓN DE MQTT ---
MQTT_OPTS=(-h "$BROKER" -p "$PORT")
[[ -n "$USER" ]] && MQTT_OPTS+=(-u "$USER" -P "$PASS")
AVAILABILITY_TOPIC="intelbras/alarm/availability"
DEVICE_ID="intelbras_alarm"
DISCOVERY_PREFIX="homeassistant"

log "Broker MQTT: $BROKER:$PORT, usuario: $USER"
log "Alarma IP: $ALARM_IP, puerto: $ALARM_PORT, zonas: $ZONE_COUNT, tam. senha: $PASSWORD_LENGTH"

# --- FUNCIONES DE DISCOVERY ---
# (Tus funciones de discovery se mantienen intactas)
publish_binary_sensor_discovery() {
    local name=$1; local uid=$2; local device_class=$3; local payload_on=$4; local payload_off=$5
    local state_topic="intelbras/alarm/${uid}"
    local payload='{"name":"'$name'","state_topic":"'$state_topic'","unique_id":"'$uid'","device_class":"'$device_class'","payload_on":"'$payload_on'","payload_off":"'$payload_off'","availability_topic":"'$AVAILABILITY_TOPIC'","device":{"identifiers":["'$DEVICE_ID'"],"name":"Alarme Intelbras","model":"AMT-8000","manufacturer":"Intelbras"}}'
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${DISCOVERY_PREFIX}/binary_sensor/${DEVICE_ID}/${uid}/config" -m "${payload}"
}

publish_text_sensor_discovery() {
    local name=$1; local uid=$2; local icon=$3
    local state_topic="intelbras/alarm/${uid}"
    local payload='{"name":"'$name'","state_topic":"'$state_topic'","unique_id":"'$uid'","icon":"'$icon'","availability_topic":"'$AVAILABILITY_TOPIC'","device":{"identifiers":["'$DEVICE_ID'"],"name":"Alarme Intelbras","model":"AMT-8000","manufacturer":"Intelbras"}}'
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${DISCOVERY_PREFIX}/sensor/${DEVICE_ID}/${uid}/config" -m "${payload}"
}

# --- NUEVO: Función de Discovery para el Panel de Alarma ---
publish_alarm_panel_discovery() {
    log "Publicando configuração do Painel de Alarme para o Home Assistant..."
    local uid="${DEVICE_ID}_panel"
    local command_topic="intelbras/alarm/command"
    local state_topic="intelbras/alarm/state"
    local payload='{'
    payload+='"name":"Painel de Alarme Intelbras",'
    payload+='"unique_id":"'$uid'",'
    payload+='"state_topic":"'$state_topic'",'
    payload+='"command_topic":"'$command_topic'",'
    payload+='"availability_topic":"'$AVAILABILITY_TOPIC'",'
    payload+='"value_template":"{% if value == \'Armada\' %}armed_away{% elif value == \'Desarmada\' %}disarmed{% else %}disarmed{% endif %}",'
    payload+='"payload_disarm":"DISARM",'
    payload+='"payload_arm_away":"ARM_AWAY",'
    payload+='"device":{"identifiers":["'$DEVICE_ID'"],"name":"Alarme Intelbras","model":"AMT-8000","manufacturer":"Intelbras"}'
    payload+='}'
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "${DISCOVERY_PREFIX}/alarm_control_panel/${DEVICE_ID}/config" -m "${payload}"
}

# --- PUBLICACIÓN DE CONFIGURACIÓN DE ENTIDADES ---
log "Configurando o Home Assistant Discovery..."
publish_text_sensor_discovery "Estado Alarma" "state" "mdi:shield-lock"
publish_text_sensor_discovery "Sirene" "sounding" "mdi:alarm-bell"
publish_binary_sensor_discovery "Pânico" "panic" "safety" "on" "off"
for i in $(seq 1 "$ZONE_COUNT"); do
    publish_binary_sensor_discovery "Zona $i" "zone_${i}" "opening" "on" "off"
done
# --- NUEVO: Llamar a la función de discovery del panel ---
publish_alarm_panel_discovery

# --- GENERACIÓN DE CONFIG.CFG ---
log "Gerando config.cfg..."
cat > /alarme-intelbras/config.cfg << EOF
[receptorip]
addr = 0.0.0.0
port = ${ALARM_PORT}
centrais = .*
maxconn = 1
caddr = ${ALARM_IP}
cport = ${ALARM_PORT}
senha = ${ALARM_PASS}
tamanho = ${PASSWORD_LENGTH}
folder_dlfoto = .
logfile = receptorip.log
EOF

# --- PUBLICACIÓN DE ESTADOS INICIALES ---
log "Publicando disponibilidade e estados iniciais..."
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "$AVAILABILITY_TOPIC" -m "online"
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "Desarmada"
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/sounding" -m "Normal"
mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/panic" -m "off"
for i in $(seq 1 "$ZONE_COUNT"); do
    mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${i}" -m "off"
done

# --- NUEVO: ESTRUCTURA DE PROCESOS PARALELOS ---

# Proceso 1: Escuchar eventos de la central (corre en segundo plano)
listen_for_events() {
    log "Iniciando receptorip para escutar eventos da central..."
    # Tu lógica original para procesar eventos se mantiene aquí
    declare -A ACTIVE_ZONES=()
    ./receptorip config.cfg 2>&1 | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        log "Evento da Central: $line"

        if echo "$line" | grep -q "Ativacao remota app"; then
            mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "Armada"
        elif echo "$line" | grep -q "Desativacao remota app"; then
            mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "Desarmada"
        elif [[ "$line" =~ Disparo\ de\ zona\ ([0-9]+) ]]; then
            local zone="${BASH_REMATCH[1]}"
            ACTIVE_ZONES["$zone"]=1
            mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${zone}" -m "on"
            mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/sounding" -m "Disparada"
        elif [[ "$line" =~ Restauracao\ de\ zona\ ([0-9]+) ]]; then
            local zone="${BASH_REMATCH[1]}"
            unset ACTIVE_ZONES["$zone"]
            mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${zone}" -m "off"
            if [[ ${#ACTIVE_ZONES[@]} -eq 0 ]]; then
                mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/sounding" -m "Normal"
            fi
        elif echo "$line" | grep -q "Panico silencioso"; then
            mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/panic" -m "on"
            (sleep 30 && mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/panic" -m "off") &
        fi
    done
}

# Proceso 2: Escuchar comandos de Home Assistant (corre en segundo plano)
listen_for_commands() {
    log "Iniciando listener de comandos MQTT de Home Assistant..."
    mosquitto_sub "${MQTT_OPTS[@]}" -t "intelbras/alarm/command" | while IFS= read -r command; do
        log "Comando MQTT recebido de Home Assistant: '$command'"
        case "$command" in
            "ARM_AWAY")
                log "Executando: ./comandar ativar"
                # Ejecuta el comando para armar la central
                ./comandar "$ALARM_IP" "$ALARM_PORT" "$ALARM_PASS" "$PASSWORD_LENGTH" ativar
                ;;
            "DISARM")
                log "Executando: ./comandar desativar"
                # Ejecuta el comando para desarmar la central
                ./comandar "$ALARM_IP" "$ALARM_PORT" "$ALARM_PASS" "$PASSWORD_LENGTH" desativar
                ;;
            *)
                log "Comando desconhecido: '$command'"
                ;;
        esac
    done
}

# --- LANZAMIENTO Y GESTIÓN DE PROCESOS ---
# Lanza ambos procesos en segundo plano y espera a que terminen.
# La trampa 'cleanup' se encargará de detenerlos cuando el add-on reciba una señal de parada.
listen_for_events &
listen_for_commands &
wait
