#!/usr/bin/with-contenv bashio

# --- FUNCIONES Y TRAPS (TRAMPAS) ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
cleanup() {
    log "Encerrando... Deteniendo procesos en segundo plano."
    pkill -P $$
    mosquitto_pub "<span class="math-inline">\{MQTT\_OPTS\[@\]\}" \-r \-t "</span>{AVAILABILITY_TOPIC}" -m "offline" || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# --- LECTURA DE CONFIGURACIÓN ---
log "=== Iniciando Intelbras MQTT Bridge Add-on (v3.1 - Corregido) ==="

ALARM_PORT=<span class="math-inline">\(bashio\:\:config 'alarm\_port'\)
ALARM\_IP\=</span>(bashio::config 'alarm_ip')
ALARM_PASS=<span class="math-inline">\(bashio\:\:config 'alarm\_password'\)
PASSWORD\_LENGTH\=</span>(bashio::config 'password_length')
ZONE_COUNT=<span class="math-inline">\(bashio\:\:config 'zone\_count'\)
BROKER\=</span>(bashio::config 'mqtt_broker')
PORT=<span class="math-inline">\(bashio\:\:config 'mqtt\_port'\)
USER\=</span>(bashio::config 'mqtt_user')
PASS=$(bashio::config 'mqtt_password')

# --- CONFIGURACIÓN DE MQTT ---
MQTT_OPTS=(-h "$BROKER" -p "$PORT")
[[ -n "$USER" ]] && MQTT_OPTS+=(-u "$USER" -P "$PASS")
AVAILABILITY_TOPIC="intelbras/alarm/availability"
DEVICE_ID="intelbras_alarm"
DISCOVERY_PREFIX="homeassistant"

log "Broker MQTT: $BROKER:$PORT, usuario: $USER"
log "Alarma IP: $ALARM_IP, puerto: $ALARM_PORT, zonas: $ZONE_COUNT, tam. senha: $PASSWORD_LENGTH"

# --- FUNCIONES DE DISCOVERY (REFACTORIZADAS PARA MAYOR SEGURIDAD) ---

publish_binary_sensor_discovery() {
    local name=$1 uid=$2 device_class=$3 payload_on=$4 payload_off=<span class="math-inline">5
local state\_topic\="intelbras/alarm/</span>{uid}"
    local payload
    # Usando un "Here Document" (<< EOM) para construir el JSON de forma segura
    read -r -d '' payload << EOM
{
    "name": "$name",
    "state_topic": "$state_topic",
    "unique_id": "$uid",
    "device_class": "$device_class",
    "payload_on": "$payload_on",
    "payload_off": "$payload_off",
    "availability_topic": "$AVAILABILITY_TOPIC",
    "device": {
        "identifiers": ["<span class="math-inline">DEVICE\_ID"\],
"name"\: "Alarme Intelbras",
"model"\: "AMT\-8000",
"manufacturer"\: "Intelbras"
\}
\}
EOM
mosquitto\_pub "</span>{MQTT_OPTS[@]}" -r -t "<span class="math-inline">\{DISCOVERY\_PREFIX\}/binary\_sensor/</span>{DEVICE_ID}/${uid}/config" -m "$payload"
}

publish_text_sensor_discovery() {
    local name=$1 uid=$2 icon=<span class="math-inline">3
local state\_topic\="intelbras/alarm/</span>{uid}"
    local payload
    read -r -d '' payload << EOM
{
    "name": "$name",
    "state_topic": "$state_topic",
    "unique_id": "$uid",
    "icon": "$icon",
    "availability_topic": "$AVAILABILITY_TOPIC",
    "device": {
        "identifiers": ["<span class="math-inline">DEVICE\_ID"\],
"name"\: "Alarme Intelbras",
"model"\: "AMT\-8000",
"manufacturer"\: "Intelbras"
\}
\}
EOM
mosquitto\_pub "</span>{MQTT_OPTS[@]}" -r -t "<span class="math-inline">\{DISCOVERY\_PREFIX\}/sensor/</span>{DEVICE_ID}/${uid}/config" -m "<span class="math-inline">payload"
\}
publish\_alarm\_panel\_discovery\(\) \{
log "Publicando configuração do Painel de Alarme para o Home Assistant\.\.\."
local uid\="</span>{DEVICE_ID}_panel"
    local command_topic="intelbras/alarm/command"
    local state_topic="intelbras/alarm/state"
    local payload
    read -r -d '' payload << EOM
{
    "name": "Painel de Alarme Intelbras",
    "unique_id": "$uid",
    "state_topic": "$state_topic",
    "command_topic": "$command_topic",
    "availability_topic": "$AVAILABILITY_TOPIC",
    "value_template": "{% if value == 'Armada' %}armed_away{% elif value == 'Desarmada' %}disarmed{% else %}disarmed{% endif %}",
    "payload_disarm": "DISARM",
    "payload_arm_away": "ARM_AWAY",
    "device": {
        "identifiers": ["<span class="math-inline">DEVICE\_ID"\],
"name"\: "Alarme Intelbras",
"model"\: "AMT\-8000",
"manufacturer"\: "Intelbras"
\}
\}
EOM
mosquitto\_pub "</span>{MQTT_OPTS[@]}" -r -t "<span class="math-inline">\{DISCOVERY\_PREFIX\}/alarm\_control\_panel/</span>{DEVICE_ID}/config" -m "$payload"
}


# --- PUBLICACIÓN DE CONFIGURACIÓN DE ENTIDADES ---
log "Configurando o Home Assistant Discovery..."
publish_text_sensor_discovery "Estado Alarma" "state" "mdi:shield-lock"
publish_text_sensor_discovery "Sirene" "sounding" "mdi:alarm-bell"
publish_binary_sensor_discovery "Pânico" "panic" "safety" "on" "off"
for i in $(seq 1 "$ZONE_COUNT"); do
    publish_binary_sensor_discovery "Zona <span class="math-inline">i" "zone\_</span>{i}" "opening" "on" "off"
done
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
tamanho = <span class="math-inline">\{PASSWORD\_LENGTH\}
folder\_dlfoto \= \.
logfile \= receptorip\.log
EOF
\# \-\-\- PUBLICACIÓN DE ESTADOS INICIALES \-\-\-
log "Publicando disponibilidade e estados iniciais\.\.\."
mosquitto\_pub "</span>{MQTT_OPTS[@]}" -r -t "<span class="math-inline">AVAILABILITY\_TOPIC" \-m "online"
mosquitto\_pub "</span>{MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "Desarmada"
mosquitto_pub "<span class="math-inline">\{MQTT\_OPTS\[@\]\}" \-r \-t "intelbras/alarm/sounding" \-m "Normal"
mosquitto\_pub "</span>{MQTT_OPTS[@]}" -r -t "intelbras/alarm/panic" -m "off"
for i in $(seq 1 "<span class="math-inline">ZONE\_COUNT"\); do
mosquitto\_pub "</span>{MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${i}" -m "off"
done

# --- ESTRUCTURA DE PROCESOS PARALELOS ---

listen_for_events() {
    log "Iniciando receptorip para escutar eventos da central..."
    declare -A ACTIVE_ZONES=()
    ./receptorip config.cfg 2>&1 | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        log "Evento da Central: $line"

        if echo "<span class="math-inline">line" \| grep \-q "Ativacao remota app"; then
mosquitto\_pub "</span>{MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "Armada"
        elif echo "<span class="math-inline">line" \| grep \-q "Desativacao remota app"; then
mosquitto\_pub "</span>{MQTT_OPTS[@]}" -r -t "intelbras/alarm/state" -m "Desarmada"
        elif [[ "<span class="math-inline">line" \=\~ Disparo\\ de\\ zona\\ \(\[0\-9\]\+\) \]\]; then
local zone\="</span>{BASH_REMATCH[1]}"
            ACTIVE_ZONES["<span class="math-inline">zone"\]\=1
mosquitto\_pub "</span>{MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${zone}" -m "on"
            mosquitto_pub "${MQTT_OPTS[@]}" -r -t "intelbras/alarm/sounding" -m "Disparada"
        elif [[ "<span class="math-inline">line" \=\~ Restauracao\\ de\\ zona\\ \(\[0\-9\]\+\) \]\]; then
local zone\="</span>{BASH_REMATCH[1]}"
            unset ACTIVE_ZONES["<span class="math-inline">zone"\]
mosquitto\_pub "</span>{MQTT_OPTS[@]}" -r -t "intelbras/alarm/zone_${zone}" -m "off"
            if [[ <span class="math-inline">\{\#ACTIVE\_ZONES\[@\]\} \-eq 0 \]\]; then
mosquitto\_pub "</span>{MQTT_OPTS[@]}" -r -t "intelbras/alarm/sounding" -m "Normal"
            fi
        elif echo "<span class="math-inline">line" \| grep \-q "Panico silencioso"; then
mosquitto\_pub "</span>{MQTT_OPTS[@]}" -r -t "intelbras/alarm/panic" -m "on"
            (sleep 30 && mosquitto_pub "<span class="math-inline">\{MQTT\_OPTS\[@\]\}" \-r \-t "intelbras/alarm/panic" \-m "off"\) &
fi
done
\}
listen\_for\_commands\(\) \{
log "Iniciando listener de comandos MQTT de Home Assistant\.\.\."
mosquitto\_sub "</span>{MQTT_OPTS[@]}" -t "intelbras/alarm/command" | while IFS= read -r command; do
        log "Comando MQTT recebido de Home Assistant: '$command'"
        case "$command" in
            "ARM_AWAY")
                log "Executando: ./comandar ativar"
                ./comandar "$ALARM_IP" "$ALARM_PORT" "$ALARM_PASS" "$PASSWORD_LENGTH" ativar
                ;;
            "DISARM")
                log "Executando: ./comandar desativar"
                ./comandar "$ALARM_IP" "$ALARM_PORT" "$ALARM_PASS" "$PASSWORD_LENGTH" desativar
                ;;
            *)
                log "Comando desconhecido: '$command'"
                ;;
        esac
    done
}

# --- LANZAMIENTO Y GESTIÓN DE PROCESOS ---
listen_for_events &
listen_for_commands &
wait
