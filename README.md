## Nomes dos integrantes

| Integrante | RM |
|---|---|
| Denise Senise | 556006 |
| Larissa Rodrigues Lapa | 554517 |
| Mateus Leme | 557803 |
| David Gabriel Gomes Fernandes | 556020 |
| Vinicius Augusto Neves Prestes | 559097 |

# Infraestrutura Linux — CitizenTech Fila Humana

Documentação dos scripts de provisionamento, monitoramento e testes de falha do servidor Linux (Ubuntu Server 22.04 / 24.04 LTS na Azure).

---

## Estrutura da pasta `infra/`

| Arquivo | Função |
|---|---|
| `provisionar_ambiente.sh` | Configura hostname, rede/IP, DNS, usuário de serviço, permissões, pacotes (.NET 10, Nginx, SQLite), publica a API e registra os serviços no `systemd`. |
| `monitor_recursos.sh` | Coleta uso de CPU, memória RAM, disco e status da API (`/health`). Gera alertas quando passa do limite e reinicia serviços caídos. |
| `simular_falhas.sh` | Executa os testes de falha (queda de serviço, estresse de CPU/RAM, erro controlado em script e checagem pós-reboot). |

---

## 1. Configuração da VM na Azure

No painel da VM na Azure (**Rede** > **Configurações de rede** > **Regra de porta de entrada**), liberar as portas TCP abaixo (além da `22` do SSH):
- `80` (Nginx - proxy reverso HTTP)
- `5153` (Kestrel - porta direta da API .NET)

Para enviar os arquivos para a VM via SSH/SCP ou Git:

```bash
# Clonar o repositório na VM
git clone <URL_DO_REPOSITORIO> ~/CitizenTech-Fila-Humana
```

Ou copiando direto da máquina local pelo PowerShell:

```powershell
scp -r ".\CitizenTech-Fila-Humana-main" usuario@IP_DA_VM:~/CitizenTech-Fila-Humana
```

---

## 2. Provisionamento do ambiente

Dentro da VM, executar o script de preparação como `root`:

```bash
cd ~/CitizenTech-Fila-Humana
chmod +x infra/*.sh
sudo bash infra/provisionar_ambiente.sh
```

O script realiza as seguintes etapas:
- **Hostname**: define o nome da máquina como `citizentech-srv`.
- **Rede e IP**: mantém o DHCP na interface principal da Azure (para não derrubar a conexão SSH), adiciona o IP interno fixo `10.200.0.10/24` (`lo:citizentech`) persistido pelo serviço `citizentech-network.service`, ajusta parâmetros TCP no `sysctl` e habilita o firewall UFW nas portas `22`, `80` e `5153`.
- **DNS**: configura o `systemd-resolved` (`/etc/systemd/resolved.conf.d/citizentech.conf`) e adiciona o domínio local `citizentech.local` e `api.citizentech.local` no `/etc/hosts`.
- **Usuários e permissões**: cria o usuário de sistema `citizentech` (sem shell de login) e aplica permissões restritas nas pastas `/opt/citizentech/app`, `/var/lib/citizentech/data`, `/etc/citizentech` e `/var/log/citizentech`.
- **Aplicação**: instala o .NET SDK 10.0 e o Nginx, grava as variáveis de ambiente em `/etc/citizentech/citizentech.env`, publica o projeto `FilaHumana.Api` e sobe os serviços `citizentech-api.service` e `nginx.service`.
- **Monitoramento**: instala o script em `/usr/local/bin/citizentech-monitor.sh`, cria os limites em `/etc/citizentech/monitor.conf` e inicia o serviço `citizentech-monitor.service`.

Evidência:
![alt text](Configuração_inicial.png)

---

## 3. Comandos de verificação

### Rede, Hostname e DNS
```bash
hostnamectl
ip -4 addr show
ip route show
getent hosts citizentech.local
resolvectl status
sudo ufw status
```
![alt text](Rede.png)

![alt text](Rede2.png)

### Usuário, diretórios e variáveis de ambiente
```bash
id citizentech
ls -la /opt/citizentech/app
ls -la /var/lib/citizentech/data
ls -la /var/log/citizentech
sudo cat /etc/citizentech/citizentech.env
```

### Teste da aplicação Web
```bash
curl -i http://citizentech.local/health
curl -s http://citizentech.local/api/locais | jq .
```
Pelo navegador externo:
- Swagger: `http://<IP_PUBLICO_VM>/swagger`
- Health check: `http://<IP_PUBLICO_VM>/health`

### Gerenciamento do serviço de monitoramento (`systemd`)
```bash
# Status dos serviços
sudo systemctl status citizentech-monitor.service
sudo systemctl status citizentech-api.service

# Execução manual com saída na tela
sudo /usr/local/bin/citizentech-monitor.sh --status

d:\Área de trabalho\infra\assets\API_Health.png
# Parar, iniciar e reiniciar o serviço

sudo systemctl stop citizentech-monitor.service
sudo systemctl start citizentech-monitor.service
sudo systemctl restart citizentech-monitor.service
```

---

## 4. Simulação de falhas e auditoria de logs

Para abrir o menu de testes de falha:

```bash
sudo bash infra/simular_falhas.sh
```

![alt text](Captura_falha.png)

![alt text](Captura_falha2.png)


Ou rodar cada teste diretamente:
- **Queda de serviços (`kill -9` no monitor e na API para validar o `Restart=always`)**:
  ```bash
  sudo bash infra/simular_falhas.sh --queda-servicos
  ```
- **Consumo elevado de CPU e Memória RAM (gera carga com `stress-ng` e grava alerta)**:
  ```bash
  sudo bash infra/simular_falhas.sh --carga-cpu-ram
  ```
- **Falha controlada em script (força erro capturado por `trap ERR`)**:
  ```bash
  sudo bash infra/simular_falhas.sh --erro-script
  ```
- **Validação pós-reboot da VM**:
  ```bash
  sudo reboot
  # Após reconectar via SSH:
  cd ~/CitizenTech-Fila-Humana
  sudo bash infra/simular_falhas.sh --pos-reboot
  ```

---

## 5. Arquivos de log (`/var/log/citizentech/`)

| Arquivo | Conteúdo |
|---|---|
| `provisionamento.log` | Instalações de pacotes, build da aplicação e configurações aplicadas no setup. |
| `monitoramento.log` | Histórico periódico de uso de CPU, RAM, disco e status HTTP do `/health`. |
| `alertas.log` | Registros de quando CPU, RAM ou disco ultrapassam os limites do `monitor.conf`. |
| `erros_falhas.log` | Quedas de serviços, recuperações automáticas e falhas de execução em scripts. |
| `auditoria.log` | Registro consolidado com data/hora, origem, ação executada e resultado. |

Para consultar os logs rapidamente:

```bash
sudo bash infra/simular_falhas.sh --ver-logs
```
![alt text](logs.png)
