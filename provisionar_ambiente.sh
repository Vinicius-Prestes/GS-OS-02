#!/bin/bash
# Script de preparação do ambiente Linux (Ubuntu Server na Azure)
# Projeto: CitizenTech - Fila Humana

set -eEuo pipefail

HOSTNAME_VM="citizentech-srv"
DOMINIO="citizentech.local"
IP_INTERNO="10.200.0.10/24"
IP_INTERNO_PURO="10.200.0.10"

USUARIO_SERVICO="citizentech"
PORTA_API="5153"
PORTA_WEB="80"

PASTA_APP="/opt/citizentech/app"
PASTA_BANCO="/var/lib/citizentech/data"
PASTA_CONF="/etc/citizentech"
PASTA_LOGS="/var/log/citizentech"

LOG_INSTALL="${PASTA_LOGS}/provisionamento.log"
LOG_MONITOR="${PASTA_LOGS}/monitoramento.log"
LOG_ALERTAS="${PASTA_LOGS}/alertas.log"
LOG_ERROS="${PASTA_LOGS}/erros_falhas.log"
LOG_AUDITORIA="${PASTA_LOGS}/auditoria.log"

DIR_ATUAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR_PROJETO="$(cd "${DIR_ATUAL}/.." && pwd)"

# Corrige quebras de linha caso os arquivos tenham vindo do Windows
sed -i 's/\r$//' "${DIR_ATUAL}"/*.sh 2>/dev/null || true

if [[ "${EUID}" -ne 0 ]]; then
    echo "Execute o script como root: sudo bash infra/provisionar_ambiente.sh"
    exit 1
fi

# Cria a pasta e os arquivos de log antes de iniciar
mkdir -p "${PASTA_LOGS}"
touch "${LOG_INSTALL}" "${LOG_MONITOR}" "${LOG_ALERTAS}" "${LOG_ERROS}" "${LOG_AUDITORIA}"
chmod 755 "${PASTA_LOGS}"
chmod 640 "${PASTA_LOGS}"/*.log

log() {
    local msg="$1"
    local data_hora
    data_hora="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${data_hora}] ${msg}" | tee -a "${LOG_INSTALL}"
}

auditar() {
    local etapa="$1"
    local status="$2"
    local detalhe="$3"
    local data_hora
    data_hora="$(date '+%Y-%m-%d %H:%M:%S')"
    local quem="${SUDO_USER:-root}"
    echo "[${data_hora}] usuario=${quem} | etapa=${etapa} | status=${status} | ${detalhe}" >> "${LOG_AUDITORIA}"
}

erro_script() {
    local cod=$?
    local linha=$1
    local cmd="${BASH_COMMAND}"
    local data_hora
    data_hora="$(date '+%Y-%m-%d %H:%M:%S')"

    echo "[${data_hora}] [ERRO] Falha no provisionamento (linha ${linha}): comando '${cmd}' retornou ${cod}" | tee -a "${LOG_INSTALL}" >> "${LOG_ERROS}"
    auditar "provisionamento" "ERRO" "Falha na linha ${linha} (${cmd}) - codigo ${cod}"
    exit "${cod}"
}

trap 'erro_script ${LINENO}' ERR

log "Iniciando configuracao do servidor CitizenTech..."
auditar "inicio_setup" "OK" "Iniciando execucao do provisionar_ambiente.sh"

# --- 1. Hostname ---
log "Configurando hostname da maquina para ${HOSTNAME_VM}..."
HOST_ANTIGO="$(hostname)"
hostnamectl set-hostname "${HOSTNAME_VM}"
auditar "hostname" "OK" "Alterado de ${HOST_ANTIGO} para ${HOSTNAME_VM}"

# --- 2. Rede e enderecamento IP ---
log "Verificando interface de rede e configurando parametros..."
IFACE="$(ip -o -4 route show to default | awk '{print $5}' | head -n1)"
if [[ -z "${IFACE}" ]]; then
    IFACE="$(ip -o link show | awk -F': ' '$2 != "lo" {print $2}' | head -n1)"
fi

IP_ATUAL="$(ip -o -4 addr show dev "${IFACE}" | awk '{print $4}' | head -n1)"
IP_SEM_MASCARA="${IP_ATUAL%/*}"
GW_ATUAL="$(ip route show default | awk '/default/ {print $3}' | head -n1)"

log "Interface principal: ${IFACE} | IP Azure: ${IP_ATUAL} | Gateway: ${GW_ATUAL}"

# Na Azure não podemos trocar o IP da placa principal manualmente senão o SSH cai.
# Por isso mantemos o IP da Azure na interface principal e adicionamos um IP fixo
# de serviço na interface local, garantindo persistência no boot via systemd.
if ! ip -4 addr show dev lo | grep -q "${IP_INTERNO_PURO}"; then
    ip addr add "${IP_INTERNO}" dev lo label "lo:citizentech"
fi

cat > /etc/sysctl.d/99-citizentech.conf <<EOF
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF
sysctl --system >> "${LOG_INSTALL}" 2>&1

cat > /etc/systemd/system/citizentech-network.service <<EOF
[Unit]
Description=Configura IP fixo interno do ambiente CitizenTech
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "ip -4 addr show dev lo | grep -q '${IP_INTERNO_PURO}' || ip addr add ${IP_INTERNO} dev lo label lo:citizentech"
ExecStop=/bin/bash -c "ip addr del ${IP_INTERNO} dev lo 2>/dev/null || true"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now citizentech-network.service >> "${LOG_INSTALL}" 2>&1
auditar "rede_ip" "OK" "Interface=${IFACE} IP_Azure=${IP_ATUAL} IP_Fixo=${IP_INTERNO} GW=${GW_ATUAL}"

# --- 3. DNS e resolução de nomes ---
log "Configurando DNS e tabela /etc/hosts..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/citizentech.conf <<EOF
[Resolve]
DNS=168.63.129.16 8.8.8.8 1.1.1.1
FallbackDNS=8.8.4.4
Domains=${DOMINIO}
EOF

if systemctl is-active --quiet systemd-resolved; then
    systemctl restart systemd-resolved
fi

sed -i '/# inicio-citizentech/,/# fim-citizentech/d' /etc/hosts
cat >> /etc/hosts <<EOF
# inicio-citizentech
127.0.1.1 ${HOSTNAME_VM}.${DOMINIO} ${HOSTNAME_VM}
${IP_SEM_MASCARA} ${HOSTNAME_VM}.${DOMINIO} ${HOSTNAME_VM} ${DOMINIO} api.${DOMINIO}
${IP_INTERNO_PURO} interno.${DOMINIO}
# fim-citizentech
EOF

TESTE_DNS="$(getent hosts "${DOMINIO}" | awk '{print $1}' | head -n1)"
log "Resolucao de nome testada: ${DOMINIO} -> ${TESTE_DNS}"
auditar "dns" "OK" "Dominio ${DOMINIO} resolvendo para ${TESTE_DNS}"

# --- 4. Usuário, diretórios e permissões ---
log "Criando usuario de servico e estrutura de pastas..."
if ! getent group "${USUARIO_SERVICO}" >/dev/null; then
    groupadd --system "${USUARIO_SERVICO}"
fi

if ! id -u "${USUARIO_SERVICO}" >/dev/null 2>&1; then
    useradd --system --gid "${USUARIO_SERVICO}" --no-create-home --home-dir /opt/citizentech --shell /usr/sbin/nologin "${USUARIO_SERVICO}"
fi

mkdir -p "${PASTA_APP}" "${PASTA_BANCO}" "${PASTA_CONF}" "${PASTA_LOGS}"

chown -R "${USUARIO_SERVICO}:${USUARIO_SERVICO}" /opt/citizentech "${PASTA_BANCO}"
chown -R root:"${USUARIO_SERVICO}" "${PASTA_CONF}" "${PASTA_LOGS}"

chmod 750 /opt/citizentech "${PASTA_APP}" "${PASTA_BANCO}" "${PASTA_CONF}"
chmod 775 "${PASTA_LOGS}"
chmod 664 "${PASTA_LOGS}"/*.log

auditar "usuarios_permissoes" "OK" "Usuario ${USUARIO_SERVICO} e permissoes configuradas em /opt/citizentech e /var/lib/citizentech"

# --- 5. Pacotes e dependências (.NET 10, Nginx, SQLite, ferramentas de monitoramento) ---
log "Instalando pacotes do sistema via apt..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >> "${LOG_INSTALL}" 2>&1
apt-get install -y curl wget jq bc sysstat stress-ng sqlite3 nginx ufw ca-certificates gnupg lsb-release apt-transport-https libicu-dev >> "${LOG_INSTALL}" 2>&1
auditar "pacotes_apt" "OK" "Instalados nginx, sqlite3, sysstat, stress-ng, ufw, jq, bc, curl"

if command -v dotnet >/dev/null 2>&1 && dotnet --list-sdks | grep -q '^10\.'; then
    log ".NET SDK 10 ja esta instalado ($(dotnet --version))."
else
    log "Instalando .NET SDK 10.0..."
    VER_UBUNTU="$(lsb_release -rs)"
    wget -q "https://packages.microsoft.com/config/ubuntu/${VER_UBUNTU}/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb || true
    if [[ -f /tmp/packages-microsoft-prod.deb ]]; then
        dpkg -i /tmp/packages-microsoft-prod.deb >> "${LOG_INSTALL}" 2>&1 || true
        rm -f /tmp/packages-microsoft-prod.deb
        apt-get update -y >> "${LOG_INSTALL}" 2>&1 || true
    fi

    if ! apt-get install -y dotnet-sdk-10.0 >> "${LOG_INSTALL}" 2>&1; then
        log "Instalando .NET 10 pelo script oficial da Microsoft..."
        curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
        chmod +x /tmp/dotnet-install.sh
        /tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet >> "${LOG_INSTALL}" 2>&1
        ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet
        ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet
        rm -f /tmp/dotnet-install.sh
    fi
fi
auditar "dotnet_sdk" "OK" "Versao $(/usr/bin/dotnet --version)"

# --- 6. Variáveis de ambiente e publicação da API ---
log "Gravando variaveis de ambiente e compilando a aplicacao Fila Humana..."
cat > "${PASTA_CONF}/citizentech.env" <<EOF
ASPNETCORE_ENVIRONMENT=Production
ASPNETCORE_URLS=http://0.0.0.0:${PORTA_API}
ConnectionStrings__FilaHumana=Data Source=${PASTA_BANCO}/fila-humana.db
DOTNET_ROOT=/usr/share/dotnet
DOTNET_CLI_TELEMETRY_OPTOUT=1
EOF

chown root:"${USUARIO_SERVICO}" "${PASTA_CONF}/citizentech.env"
chmod 640 "${PASTA_CONF}/citizentech.env"

CSPROJ="${DIR_PROJETO}/src/FilaHumana.Api/FilaHumana.Api.csproj"
/usr/bin/dotnet publish "${CSPROJ}" -c Release -o "${PASTA_APP}" >> "${LOG_INSTALL}" 2>&1

chown -R "${USUARIO_SERVICO}:${USUARIO_SERVICO}" /opt/citizentech "${PASTA_BANCO}"
chmod -R 750 "${PASTA_APP}" "${PASTA_BANCO}"
auditar "build_app" "OK" "Aplicacao publicada em ${PASTA_APP}"

# --- 7. Serviço da aplicação, Nginx e Firewall ---
log "Configurando servico citizentech-api no systemd..."
cat > /etc/systemd/system/citizentech-api.service <<EOF
[Unit]
Description=API CitizenTech Fila Humana (.NET)
After=network.target citizentech-network.service

[Service]
Type=simple
User=${USUARIO_SERVICO}
Group=${USUARIO_SERVICO}
WorkingDirectory=${PASTA_APP}
EnvironmentFile=${PASTA_CONF}/citizentech.env
ExecStart=/usr/bin/dotnet ${PASTA_APP}/FilaHumana.Api.dll
Restart=always
RestartSec=5
StartLimitIntervalSec=0
SyslogIdentifier=citizentech-api
StandardOutput=append:${PASTA_LOGS}/aplicacao.log
StandardError=append:${LOG_ERROS}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable citizentech-api.service >> "${LOG_INSTALL}" 2>&1
systemctl restart citizentech-api.service

log "Configurando proxy reverso no Nginx (porta ${PORTA_WEB} -> ${PORTA_API})..."
cat > /etc/nginx/sites-available/citizentech <<EOF
server {
    listen ${PORTA_WEB} default_server;
    listen [::]:${PORTA_WEB} default_server;
    server_name ${HOSTNAME_VM} ${DOMINIO} api.${DOMINIO} _;

    access_log ${PASTA_LOGS}/nginx_access.log;
    error_log ${PASTA_LOGS}/nginx_error.log;

    location / {
        proxy_pass http://127.0.0.1:${PORTA_API};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/citizentech /etc/nginx/sites-enabled/citizentech
rm -f /etc/nginx/sites-enabled/default

nginx -t >> "${LOG_INSTALL}" 2>&1
systemctl enable nginx.service >> "${LOG_INSTALL}" 2>&1
systemctl restart nginx.service

log "Liberando portas 22, ${PORTA_WEB} e ${PORTA_API} no UFW..."
ufw allow 22/tcp >> "${LOG_INSTALL}" 2>&1
ufw allow "${PORTA_WEB}/tcp" >> "${LOG_INSTALL}" 2>&1
ufw allow "${PORTA_API}/tcp" >> "${LOG_INSTALL}" 2>&1
ufw --force enable >> "${LOG_INSTALL}" 2>&1

auditar "servicos_web" "OK" "citizentech-api e nginx ativos; firewall configurado"

# --- 8. Serviço de monitoramento contínuo ---
log "Configurando script e servico de monitoramento no systemd..."
cat > "${PASTA_CONF}/monitor.conf" <<EOF
LIMITE_CPU=75
LIMITE_MEM=80
LIMITE_DISCO=85
INTERVALO_SEGUNDOS=15
URL_HEALTH="http://127.0.0.1:${PORTA_API}/health"
SERVICO_API="citizentech-api.service"
SERVICO_PROXY="nginx.service"
EOF
chmod 644 "${PASTA_CONF}/monitor.conf"

cp "${DIR_ATUAL}/monitor_recursos.sh" /usr/local/bin/citizentech-monitor.sh
sed -i 's/\r$//' /usr/local/bin/citizentech-monitor.sh
chmod 755 /usr/local/bin/citizentech-monitor.sh

cat > /etc/systemd/system/citizentech-monitor.service <<EOF
[Unit]
Description=Monitoramento de Recursos e Servicos CitizenTech
After=network.target citizentech-api.service

[Service]
Type=simple
User=root
EnvironmentFile=-${PASTA_CONF}/monitor.conf
ExecStart=/usr/local/bin/citizentech-monitor.sh --daemon
Restart=always
RestartSec=3
StartLimitIntervalSec=0
SyslogIdentifier=citizentech-monitor
StandardOutput=append:${LOG_MONITOR}
StandardError=append:${LOG_ERROS}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable citizentech-monitor.service >> "${LOG_INSTALL}" 2>&1
systemctl restart citizentech-monitor.service
auditar "servico_monitor" "OK" "citizentech-monitor.service habilitado e iniciado"

# --- 9. Teste final da aplicação ---
log "Testando resposta da API (/health)..."
STATUS_API="000"
for _ in {1..15}; do
    STATUS_API="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORTA_API}/health" || true)"
    if [[ "${STATUS_API}" == "200" ]]; then
        break
    fi
    sleep 2
done

STATUS_NGINX="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORTA_WEB}/health" || true)"

if [[ "${STATUS_API}" == "200" && "${STATUS_NGINX}" == "200" ]]; then
    log "Aplicacao respondendo normalmente (HTTP 200 na porta ${PORTA_API} e no Nginx porta ${PORTA_WEB})."
    auditar "validacao_final" "OK" "Health check retornou 200"
else
    log "Erro: a aplicacao nao respondeu como esperado (API=${STATUS_API}, Nginx=${STATUS_NGINX})."
    auditar "validacao_final" "ERRO" "API=${STATUS_API} Nginx=${STATUS_NGINX}"
    exit 1
fi

IP_PUBLICO="$(curl -s --max-time 4 https://ifconfig.me || echo '<IP_DA_VM>')"

echo ""
echo "--- Provisionamento concluido ---"
echo "Hostname : $(hostnamectl --static)"
echo "IP Local : ${IP_ATUAL} (IP interno fixo: ${IP_INTERNO})"
echo "Swagger  : http://${IP_PUBLICO}/swagger"
echo "Health   : http://${IP_PUBLICO}/health"
echo "Logs     : ${PASTA_LOGS}"
echo ""
