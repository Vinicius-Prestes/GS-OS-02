#!/bin/bash
# Script para testes de falha e validação dos logs
# Testa queda de serviço, pico de CPU/RAM, erro controlado em script e pós-reboot

set -uo pipefail

PASTA_LOGS="/var/log/citizentech"
ARQ_CONF="/etc/citizentech/monitor.conf"

LOG_INSTALL="${PASTA_LOGS}/provisionamento.log"
LOG_MONITOR="${PASTA_LOGS}/monitoramento.log"
LOG_ALERTAS="${PASTA_LOGS}/alertas.log"
LOG_ERROS="${PASTA_LOGS}/erros_falhas.log"
LOG_AUDITORIA="${PASTA_LOGS}/auditoria.log"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Execute com sudo: sudo bash infra/simular_falhas.sh"
    exit 1
fi

mkdir -p "${PASTA_LOGS}"
touch "${LOG_MONITOR}" "${LOG_ALERTAS}" "${LOG_ERROS}" "${LOG_AUDITORIA}"

registrar_teste() {
    local teste="$1"
    local status="$2"
    local msg="$3"
    local dt
    dt="$(date '+%Y-%m-%d %H:%M:%S')"

    echo "[${dt}] [TESTE:${teste}] (${status}) ${msg}" | tee -a "${LOG_ERROS}"
    echo "[${dt}] origem=simular_falhas | teste=${teste} | status=${status} | ${msg}" >> "${LOG_AUDITORIA}"
}

# 1. Queda manual do serviço de monitoramento e da API
teste_queda_servicos() {
    echo ""
    echo "--- Teste 1: Interrupcao e recuperacao dos servicos ---"

    local pid_mon_antes
    pid_mon_antes="$(systemctl show -p MainPID --value citizentech-monitor.service)"
    echo "Matando processo do citizentech-monitor.service (PID ${pid_mon_antes})..."
    registrar_teste "queda_monitor" "INICIADO" "Enviando kill -9 para o PID ${pid_mon_antes}"
    kill -9 "${pid_mon_antes}" 2>/dev/null || true

    echo "Aguardando 5s para o systemd subir o servico novamente..."
    sleep 5

    local st_mon pid_mon_depois
    st_mon="$(systemctl is-active citizentech-monitor.service || true)"
    pid_mon_depois="$(systemctl show -p MainPID --value citizentech-monitor.service)"

    if [[ "${st_mon}" == "active" && "${pid_mon_depois}" != "${pid_mon_antes}" ]]; then
        registrar_teste "queda_monitor" "RECUPERADO" "Monitor voltou ativo com novo PID ${pid_mon_depois} (anterior: ${pid_mon_antes})"
    else
        systemctl start citizentech-monitor.service
        pid_mon_depois="$(systemctl show -p MainPID --value citizentech-monitor.service)"
        registrar_teste "queda_monitor" "REINICIADO" "Monitor iniciado com PID ${pid_mon_depois}"
    fi

    echo ""
    local pid_api_antes
    pid_api_antes="$(systemctl show -p MainPID --value citizentech-api.service)"
    echo "Matando processo da API .NET citizentech-api.service (PID ${pid_api_antes})..."
    registrar_teste "queda_api" "INICIADO" "Enviando kill -9 para a API (PID ${pid_api_antes})"
    kill -9 "${pid_api_antes}" 2>/dev/null || true

    echo "Aguardando 6s para recuperacao da API..."
    sleep 6

    local st_api pid_api_depois http_code
    st_api="$(systemctl is-active citizentech-api.service || true)"
    pid_api_depois="$(systemctl show -p MainPID --value citizentech-api.service)"
    http_code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5153/health || echo '000')"

    registrar_teste "queda_api" "RECUPERADO" "API=${st_api} | Novo PID=${pid_api_depois} | /health=HTTP_${http_code}"
}

# 2. Simulação de consumo alto de CPU e Memória
teste_carga_recursos() {
    echo ""
    echo "--- Teste 2: Simulacao de consumo elevado de CPU e RAM ---"

    local cpus
    cpus="$(nproc 2>/dev/null || echo 2)"
    registrar_teste "estresse_cpu_ram" "INICIADO" "Gerando carga em ${cpus} CPUs e memoria por 15s"

    # Baixa o limite temporariamente durante o teste para forçar o disparo do alerta no log
    if [[ -f "${ARQ_CONF}" ]]; then
        cp "${ARQ_CONF}" "${ARQ_CONF}.bak"
        sed -i 's/^LIMITE_CPU=.*/LIMITE_CPU=25/' "${ARQ_CONF}"
        sed -i 's/^LIMITE_MEM=.*/LIMITE_MEM=15/' "${ARQ_CONF}"
    fi

    if command -v stress-ng >/dev/null 2>&1; then
        stress-ng --cpu "${cpus}" --vm 1 --vm-bytes 256M --timeout 15s --quiet &
        local pid_carga=$!
    else
        for _ in $(seq 1 "${cpus}"); do
            (while true; do :; done) &
        done
        local pid_carga=$!
    fi

    sleep 3
    echo "Rodando coleta do monitor durante o pico..."
    /usr/local/bin/citizentech-monitor.sh --once || bash "$(dirname "$0")/monitor_recursos.sh" --once

    wait "${pid_carga}" 2>/dev/null || true
    pkill -f "stress-ng" 2>/dev/null || true

    if [[ -f "${ARQ_CONF}.bak" ]]; then
        mv "${ARQ_CONF}.bak" "${ARQ_CONF}"
    fi

    registrar_teste "estresse_cpu_ram" "OK" "Teste finalizado. Alertas gravados em ${LOG_ALERTAS}"
    echo ""
    echo "Ultimos alertas gerados:"
    tail -n 5 "${LOG_ALERTAS}"
}

# 3. Falha controlada em script
teste_erro_script() {
    echo ""
    echo "--- Teste 3: Falha controlada em script ---"

    (
        set -eEo pipefail
        tratar_falha_teste() {
            local cod=$?
            local lin=$1
            local cmd="$2"
            local dt
            dt="$(date '+%Y-%m-%d %H:%M:%S')"
            echo "[${dt}] [ERRO_SCRIPT] Falha na linha ${lin} ao rodar '${cmd}' (codigo ${cod})" | tee -a "${LOG_ERROS}"
            echo "[${dt}] origem=script_backup_teste | evento=falha_controlada | linha=${lin} | codigo=${cod} | cmd='${cmd}'" >> "${LOG_AUDITORIA}"
        }
        trap 'tratar_falha_teste ${LINENO} "${BASH_COMMAND}"' ERR

        # Tenta fazer backup de um arquivo que não existe para forçar o erro
        cp /var/lib/citizentech/data/arquivo_inexistente.db /tmp/teste_backup.db 2>/dev/null
    ) || true

    echo "Ultimas linhas do log de erros (${LOG_ERROS}):"
    tail -n 4 "${LOG_ERROS}"
}

# 4. Verificação pós-reboot da VM
teste_pos_reboot() {
    echo ""
    echo "--- Teste 4: Verificacao dos servicos apos reinicializacao da VM ---"

    local boot_time tempo_ativo st_api st_mon st_ngx cod_http
    boot_time="$(who -b | awk '{print $3, $4}')"
    tempo_ativo="$(uptime -p)"
    st_api="$(systemctl is-active citizentech-api.service || echo 'parado')"
    st_mon="$(systemctl is-active citizentech-monitor.service || echo 'parado')"
    st_ngx="$(systemctl is-active nginx.service || echo 'parado')"
    cod_http="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5153/health || echo '000')"

    echo "Boot da VM          : ${boot_time} (${tempo_ativo})"
    echo "Hostname            : $(hostnamectl --static)"
    echo "citizentech-api     : ${st_api} (boot: $(systemctl is-enabled citizentech-api.service 2>/dev/null))"
    echo "citizentech-monitor : ${st_mon} (boot: $(systemctl is-enabled citizentech-monitor.service 2>/dev/null))"
    echo "nginx               : ${st_ngx} (boot: $(systemctl is-enabled nginx.service 2>/dev/null))"
    echo "Endpoint /health    : HTTP ${cod_http}"

    registrar_teste "pos_reboot" "OK" "Boot='${boot_time}' API=${st_api} Monitor=${st_mon} Nginx=${st_ngx} Health=HTTP_${cod_http}"
}

mostrar_logs() {
    echo ""
    echo "=== 1. provisionamento.log (ultimas 8 linhas) ==="
    tail -n 8 "${LOG_INSTALL}" 2>/dev/null || true
    echo ""
    echo "=== 2. monitoramento.log (ultimas 6 linhas) ==="
    tail -n 6 "${LOG_MONITOR}" 2>/dev/null || true
    echo ""
    echo "=== 3. alertas.log (ultimas 6 linhas) ==="
    tail -n 6 "${LOG_ALERTAS}" 2>/dev/null || true
    echo ""
    echo "=== 4. erros_falhas.log (ultimas 8 linhas) ==="
    tail -n 8 "${LOG_ERROS}" 2>/dev/null || true
    echo ""
    echo "=== 5. auditoria.log (ultimas 10 linhas) ==="
    tail -n 10 "${LOG_AUDITORIA}" 2>/dev/null || true
}

menu() {
    while true; do
        echo ""
        echo "--- Testes de Falha e Logs (CitizenTech) ---"
        echo "1) Queda e recuperacao dos servicos (Monitor e API)"
        echo "2) Simular pico de CPU e Memoria RAM"
        echo "3) Provocar falha controlada em script"
        echo "4) Validar servicos pos-reboot da VM"
        echo "5) Rodar todos os testes (1 a 4)"
        echo "6) Ver resumo dos arquivos de log"
        echo "0) Sair"
        read -rp "Opcao: " op

        case "${op}" in
            1) teste_queda_servicos ;;
            2) teste_carga_recursos ;;
            3) teste_erro_script ;;
            4) teste_pos_reboot ;;
            5)
                teste_queda_servicos
                teste_carga_recursos
                teste_erro_script
                teste_pos_reboot
                mostrar_logs
                ;;
            6) mostrar_logs ;;
            0) exit 0 ;;
            *) echo "Opcao invalida." ;;
        esac
    done
}

ACAO="${1:---menu}"

case "${ACAO}" in
    --queda-servicos|--queda-monitor) teste_queda_servicos ;;
    --carga-cpu-ram) teste_carga_recursos ;;
    --erro-script) teste_erro_script ;;
    --pos-reboot) teste_pos_reboot ;;
    --evidencias|--ver-logs) mostrar_logs ;;
    --tudo)
        teste_queda_servicos
        teste_carga_recursos
        teste_erro_script
        teste_pos_reboot
        mostrar_logs
        ;;
    *) menu ;;
esac
