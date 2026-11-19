#!/bin/bash
# Monitoramento de CPU, memória RAM, disco e status dos serviços
# Pode rodar avulso (--once / --status) ou em loop contínuo pelo systemd (--daemon)

set -uo pipefail

ARQ_CONF="/etc/citizentech/monitor.conf"
if [[ -f "${ARQ_CONF}" ]]; then
    source "${ARQ_CONF}"
fi

LIMITE_CPU="${LIMITE_CPU:-75}"
LIMITE_MEM="${LIMITE_MEM:-80}"
LIMITE_DISCO="${LIMITE_DISCO:-85}"
INTERVALO_SEGUNDOS="${INTERVALO_SEGUNDOS:-15}"
URL_HEALTH="${URL_HEALTH:-http://127.0.0.1:5153/health}"
SERVICO_API="${SERVICO_API:-citizentech-api.service}"
SERVICO_PROXY="${SERVICO_PROXY:-nginx.service}"

PASTA_LOGS="/var/log/citizentech"
LOG_MONITOR="${PASTA_LOGS}/monitoramento.log"
LOG_ALERTAS="${PASTA_LOGS}/alertas.log"
LOG_ERROS="${PASTA_LOGS}/erros_falhas.log"
LOG_AUDITORIA="${PASTA_LOGS}/auditoria.log"

mkdir -p "${PASTA_LOGS}"
touch "${LOG_MONITOR}" "${LOG_ALERTAS}" "${LOG_ERROS}" "${LOG_AUDITORIA}"

agora() {
    date '+%Y-%m-%d %H:%M:%S'
}

registrar_alerta() {
    local recurso="$1"
    local atual="$2"
    local limite="$3"
    local extra="$4"
    local dt
    dt="$(agora)"

    local linha="[${dt}] [ALERTA] ${recurso} acima do limite: ${atual}% (limite ${limite}%) | ${extra}"
    echo "${linha}" >> "${LOG_ALERTAS}"
    echo "${linha}" >> "${LOG_MONITOR}"
    echo "[${dt}] origem=monitor | evento=alerta_${recurso} | uso=${atual}% | limite=${limite}% | ${extra}" >> "${LOG_AUDITORIA}"
}

registrar_falha() {
    local evento="$1"
    local servico="$2"
    local msg="$3"
    local dt
    dt="$(agora)"

    local linha="[${dt}] [${evento}] ${servico}: ${msg}"
    echo "${linha}" >> "${LOG_ERROS}"
    echo "${linha}" >> "${LOG_MONITOR}"
    echo "[${dt}] origem=monitor | evento=${evento} | servico=${servico} | ${msg}" >> "${LOG_AUDITORIA}"
}

checar_servicos() {
    local situacao="OK"

    if ! systemctl is-active --quiet "${SERVICO_API}"; then
        situacao="RECUPERADO"
        registrar_falha "SERVICO_PARADO" "${SERVICO_API}" "Servico da API encontrado parado. Tentando reiniciar..."
        if systemctl restart "${SERVICO_API}" 2>/dev/null; then
            sleep 2
            local pid_novo
            pid_novo="$(systemctl show -p MainPID --value "${SERVICO_API}" 2>/dev/null || echo '?')"
            registrar_falha "RECUPERADO" "${SERVICO_API}" "Servico reiniciado automaticamente (PID ${pid_novo})"
        else
            situacao="ERRO"
            registrar_falha "FALHA_REINICIO" "${SERVICO_API}" "Nao foi possivel reiniciar o servico"
        fi
    fi

    if ! systemctl is-active --quiet "${SERVICO_PROXY}"; then
        situacao="RECUPERADO"
        registrar_falha "SERVICO_PARADO" "${SERVICO_PROXY}" "Nginx encontrado parado. Reiniciando..."
        if systemctl restart "${SERVICO_PROXY}" 2>/dev/null; then
            registrar_falha "RECUPERADO" "${SERVICO_PROXY}" "Nginx reiniciado com sucesso"
        else
            situacao="ERRO"
            registrar_falha "FALHA_REINICIO" "${SERVICO_PROXY}" "Erro ao reiniciar o Nginx"
        fi
    fi

    local http_code
    http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "${URL_HEALTH}" || echo '000')"
    if [[ "${http_code}" != "200" ]]; then
        registrar_falha "FALHA_HEALTH" "${SERVICO_API}" "Health check respondeu HTTP ${http_code}. Reiniciando API..."
        systemctl restart "${SERVICO_API}" 2>/dev/null || true
        sleep 3
        http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "${URL_HEALTH}" || echo '000')"
        if [[ "${http_code}" == "200" ]]; then
            situacao="RECUPERADO"
            registrar_falha "RECUPERADO" "${SERVICO_API}" "Health check normalizado (HTTP 200)"
        else
            situacao="ERRO"
            registrar_falha "ERRO_HEALTH" "${SERVICO_API}" "Health check continua falhando (HTTP ${http_code})"
        fi
    fi

    echo "${situacao} ${http_code}"
}

verificar_recursos() {
    local mostrar_tela="${1:-nao}"

    if [[ -f "${ARQ_CONF}" ]]; then
        source "${ARQ_CONF}"
    fi

    # CPU: usa vmstat (coluna 15 é o % idle na segunda amostra de 1s)
    local cpu_idle cpu_uso
    cpu_idle="$(vmstat 1 2 | tail -1 | awk '{print $15}')"
    cpu_uso=$((100 - cpu_idle))

    # Memória RAM: extrai total, usada e disponível em MB pelo comando free -m
    local mem_total mem_usada mem_disp mem_pct
    read -r mem_total mem_usada mem_disp <<< "$(free -m | awk 'NR==2 {print $2, ($2 - $7), $7}')"
    mem_pct=$(( (mem_usada * 100) / mem_total ))

    # Disco: partição raiz (/) em MB
    local disco_pct disco_usado disco_disp disco_total
    read -r disco_pct disco_usado disco_disp disco_total <<< "$(df -BM / | awk 'NR==2 {gsub(/M/,""); gsub(/%/,""); print $5, $3, $4, $2}')"

    # Saúde da aplicação e serviços
    local status_srv cod_http
    read -r status_srv cod_http <<< "$(checar_servicos)"

    local dt
    dt="$(agora)"
    local resumo="CPU=${cpu_uso}% | RAM=${mem_pct}% (usada:${mem_usada}MB disp:${mem_disp}MB) | DISCO=${disco_pct}% (usado:${disco_usado}MB disp:${disco_disp}MB) | Health=HTTP_${cod_http} | Status=${status_srv}"

    echo "[${dt}] [OK] ${resumo}" >> "${LOG_MONITOR}"
    echo "[${dt}] origem=monitor | evento=coleta | status=${status_srv} | ${resumo}" >> "${LOG_AUDITORIA}"

    # Checa se algum recurso passou do limite configurado
    local top_proc
    if [[ "${cpu_uso}" -ge "${LIMITE_CPU}" ]]; then
        top_proc="$(ps -eo pid,comm,%cpu --sort=-%cpu | awk 'NR>1 && NR<=3 {printf "%s(PID %s: %s%%) ", $2, $1, $3}')"
        registrar_alerta "CPU" "${cpu_uso}" "${LIMITE_CPU}" "Processos: ${top_proc}"
    fi

    if [[ "${mem_pct}" -ge "${LIMITE_MEM}" ]]; then
        top_proc="$(ps -eo pid,comm,%mem --sort=-%mem | awk 'NR>1 && NR<=3 {printf "%s(PID %s: %s%%) ", $2, $1, $3}')"
        registrar_alerta "RAM" "${mem_pct}" "${LIMITE_MEM}" "Usada=${mem_usada}MB Disp=${mem_disp}MB | Processos: ${top_proc}"
    fi

    if [[ "${disco_pct}" -ge "${LIMITE_DISCO}" ]]; then
        registrar_alerta "DISCO" "${disco_pct}" "${LIMITE_DISCO}" "Particao=/ Usado=${disco_usado}MB Disp=${disco_disp}MB"
    fi

    if [[ "${mostrar_tela}" == "sim" ]]; then
        echo "--- Monitoramento CitizenTech (${dt}) ---"
        echo "CPU         : ${cpu_uso}% (limite: ${LIMITE_CPU}%)"
        echo "Memoria RAM : ${mem_pct}% - usada: ${mem_usada} MB / disponivel: ${mem_disp} MB / total: ${mem_total} MB (limite: ${LIMITE_MEM}%)"
        echo "Disco (/)   : ${disco_pct}% - usado: ${disco_usado} MB / disponivel: ${disco_disp} MB / total: ${disco_total} MB (limite: ${LIMITE_DISCO}%)"
        echo "API Health  : HTTP ${cod_http} (${URL_HEALTH}) - Servicos: ${status_srv}"
    fi
}

parar_servico() {
    registrar_falha "PARADA_MONITOR" "citizentech-monitor.service" "Servico de monitoramento recebeu sinal de parada (PID $$)"
    exit 0
}

rodar_daemon() {
    trap 'parar_servico' SIGTERM SIGINT

    local dt
    dt="$(agora)"
    echo "[${dt}] [INICIO] Daemon de monitoramento iniciado (PID $$, intervalo ${INTERVALO_SEGUNDOS}s)" >> "${LOG_MONITOR}"
    echo "[${dt}] origem=monitor | evento=inicio_daemon | pid=$$ | intervalo=${INTERVALO_SEGUNDOS}s" >> "${LOG_AUDITORIA}"

    while true; do
        verificar_recursos "nao"
        sleep "${INTERVALO_SEGUNDOS}"
    done
}

MODO="${1:---once}"

case "${MODO}" in
    --daemon)
        rodar_daemon
        ;;
    --once)
        verificar_recursos "sim"
        ;;
    --status)
        verificar_recursos "sim"
        echo ""
        echo "Status no systemd:"
        systemctl status "${SERVICO_API}" "${SERVICO_PROXY}" citizentech-monitor.service --no-pager -n 2 || true
        echo ""
        echo "Ultimas leituras (${LOG_MONITOR}):"
        tail -n 5 "${LOG_MONITOR}" 2>/dev/null || true
        echo ""
        echo "Ultimos alertas (${LOG_ALERTAS}):"
        tail -n 5 "${LOG_ALERTAS}" 2>/dev/null || true
        ;;
    *)
        echo "Uso: $0 [--once | --daemon | --status]"
        exit 1
        ;;
esac
