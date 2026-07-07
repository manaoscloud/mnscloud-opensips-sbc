# OpenSIPS SBC

Este diretório documenta o uso do OpenSIPS como SBC do mnscloud.

## Modelo

- SBC é separado de Softswitch.
- O servidor físico mantém a URL base da API em `/etc/mnscloud/sbc/api.base`.
- O servidor físico mantém UUID local em `/etc/mnscloud/sbc/node.uuid`.
- O servidor físico mantém token local em `/etc/mnscloud/sbc/api.token`.
- O servidor físico deve ter `mnscloud-agent` instalado, enrolado, ativo e atualizado com suporte
  ao job `voip.sbc.runtime` antes da instalação do SBC. O instalador valida isso pelo contrato
  central `/opt/mnscloud/mnscloud-agent/scripts/validate-agent.sh`.
- Esse UUID é vinculado ao cadastro `VoipSbcServer.VbsNodeUUID`.
- O hash do token é salvo em `VoipSbcServer.VbsApiTokenHash`.
- Cada requisição runtime enviada ao mnscloud usa `node_uuid` e `Authorization: Bearer <token>` para validar o servidor.

## Cadastros

- `VoipSbcServer`: servidores OpenSIPS/Kamailio/SBC autorizados no master.
- `VoipSbcServer.RealtimeMediaServerRmsUUID`: servidor `mnscloud-media` usado para ancorar RTP/SRTP quando necessário.
- `VoipSbcAccount`: conta SBC do tenant associada a um servidor SBC master.
- `VoipSbcInterface`: listeners/sockets SIP locais do servidor SBC, controlados pelo master.
- `VoipSbcPeer`: identidade de interconexão SIP inbound, com autenticação, registro, origem
  autorizada, SIP-I/SIP-T, limites e monitoramento.
- `VoipSbcPipe`: fluxo tenant-aware que liga Inbound a Outbound,
  mantendo host, porta, transporte, failover, interface, critérios opcionais, mídia, codecs e
  comportamento operacional.
- `VoipSbcManipulation`: manipulações SIP vinculadas ao pipe.

## Endpoints Runtime

- `POST /api/v1/sbc/runtime/heartbeat`
- `POST /api/v1/sbc/runtime/bootstrap`
- `POST /api/v1/sbc/runtime/auth`
- `POST /api/v1/sbc/runtime/config`
- `POST /api/v1/sbc/runtime/pipe`
- `POST /api/v1/sbc/runtime/peer-status`
- `POST /api/v1/sbc/runtime/accounting`

O `node_uuid` pode ir via query string ou header `X-SBC-Node-UUID`. O token é gerado
pelo instalador, enviado como `Authorization: Bearer <token>` no bootstrap e nas
consultas runtime, e somente o hash fica salvo no banco.

O lookup de `pipe` envia contexto SIP suficiente para identificar o Inbound e selecionar o
fluxo multi-tenant correto: direção, destino/RURI, IP/porta/transporte de origem, IP/porta local,
From, To, R-URI domain e usuário de autenticação quando disponível. A API/control plane primeiro
resolve a interconexão de entrada (`inputPeerUUID`) e depois escolhe um único `VoipSbcPipe`
ativo para o par `Inbound -> Outbound`. Critérios como IP, porta, domínio, From/To e
destino são refinadores de match, não a identidade principal do fluxo. Empates são tratados como
ambiguidade e a chamada não deve ser encaminhada automaticamente.

O endpoint `runtime/config` é exclusivo do runtime autenticado do SBC. Ele entrega a configuração
ativa de interfaces, peers e pipes para o servidor autorizado, incluindo credenciais necessárias
para `REGISTER` ativo. Essas credenciais não são expostas ao app tenant e ficam gravadas localmente
em arquivos protegidos sob `/etc/mnscloud/sbc`.

## Instalação

```bash
bash scripts/install-opensips-sbc.sh
```

O instalador:

- valida primeiro o `mnscloud-agent` com `validate-agent.sh --require-active --require-enrolled
  --require-job voip.sbc.runtime`; se não estiver pronto, a instalação para para evitar um SBC sem realtime sync;
- aceita `MNSCLOUD_API_BASE`, `MNSCLOUD_SBC_NODE_UUID`, `MNSCLOUD_SBC_API_TOKEN` e
  `MNSCLOUD_SBC_ENGINE` quando o comando é gerado pela API, persistindo esses valores antes do
  bootstrap;
- solicita a URL base da API na primeira execução manual e salva em `/etc/mnscloud/sbc/api.base`;
- configura o repositório oficial OpenSIPS 3.6.x LTS antes da instalação;
  - Debian 12 Bookworm: `https://apt.opensips.org` com componente `3.6-releases` e keyring `/usr/share/keyrings/opensips.gpg`;
  - Rocky 8/9: `https://yum.opensips.org/3.6/releases/st/<major>/<arch>/`;
- instala OpenSIPS e módulos HTTP/REST/JSON;
- instala ferramentas de troubleshooting como `sngrep`, `tcpdump`, `ngrep`, `ping`, `mtr`, `jq` e `curl`;
- cria ou reaproveita `/etc/mnscloud/sbc/node.uuid`;
- cria ou reaproveita `/etc/mnscloud/sbc/api.token`;
- tenta vincular o node UUID via API bootstrap usando hostname, IPv4 privado e IPv4 público descoberto;
- prepara os diretórios locais de runtime; a configuração ativa é gerada somente pelo job Agent
  `voip.sbc.runtime`;
- o job Agent gera `/etc/mnscloud/sbc/runtime/config.json` com a configuração ativa retornada pela
  API;
- o job Agent gera `/etc/mnscloud/sbc/dbtext/registrant` para o módulo oficial `uac_registrant`;
- não executa SQL direto nem instala cliente MariaDB para vincular o node UUID;
- faz backup de `/etc/opensips/opensips.cfg` como `.bkp`;
- gera uma configuração limpa mínima para consulta HTTP ao mnscloud;
- grava o Bearer token local no `opensips.cfg` para autenticar as chamadas runtime contra a API;
- grava `/etc/mnscloud/sbc/media.socket` quando a API retorna `rtpengineSocket`;
- habilita `rtpengine.so` e `rtpengine_offer/answer/delete` apenas quando existe media relay associado;
- anuncia o socket SIP com o IPv4 público detectado, ou o primeiro IPv4 privado como fallback;
- aplica `record_route()` em chamadas encaminhadas para manter ACK/BYE/re-INVITE no caminho do SBC;
- descarta ACK in-dialog sem `Route` de forma silenciosa/fail-closed para evitar nova decisão de
  Pipe e loop local contra o próprio SBC;
- define os cabeçalhos SIP gerados `Server` e `User-Agent` como `MNSCloud OpenSIPS SBC`;
- define `mpath` no `opensips.cfg` conforme a distro/arquitetura para carregar os módulos oficiais instalados em `/usr/lib/<multiarch>/opensips/modules/` ou `/usr/lib64/opensips/modules/`.
- carrega explicitamente `proto_udp.so` e `proto_tcp.so`, exigidos pelo OpenSIPS 3.6 para escutar nos sockets SIP UDP/TCP.
- usa `sl_send_reply()` do módulo `sl.so` e `rest_post()` no formato OpenSIPS 3.6 para consultar a API de roteamento com contexto SIP completo.
- usa `$si`/`$sp` para origem remota e `$socket_in(proto|ip|port)` para o socket local recebido, conforme as pseudo-variáveis oficiais do OpenSIPS 3.6.
- carrega `db_text.so`, `uac_auth.so`, `uac.so`, `uac_registrant.so` e `mi_fifo.so` quando os
  módulos existem no host; se algum deles estiver ausente, o instalador avisa e não habilita
  `REGISTER` ativo para evitar configuração quebrada.
- expõe MI FIFO em `/run/opensips/mnscloud_sbc_fifo`, evitando `/tmp` por causa das proteções de
  FIFO em Linux moderno.
- antes de recarregar registros SIP, compara a tabela `registrant` anterior com a nova e chama
  `reg_disable` para peers `register` removidos, enviando unREGISTER para o registrar remoto
  quando o módulo oficial conseguir fazê-lo.
- recarrega registros SIP com o MI `reg_reload` pelo FIFO local quando o control plane altera
  peers `register`, mantendo o processo OpenSIPS ativo.
- remove qualquer unidade legada `mnscloud-opensips-sbc-sync.timer`/service; alterações de runtime
  devem chegar pelo job `voip.sbc.runtime` do `mnscloud-agent`, sem reconciliador periódico.
- atualiza/reinicia o `mnscloud-agent` no fim da instalação para republicar a capacidade
  `voip.sbc.manage`, informar ausência de runtime local e receber o job inicial de sync pela API.

## Autenticação de peers

- `ip`: usado para peers por IP. A API identifica o Inbound por `VspAllowedSourceAddresses`
  e só encaminha quando encontra um pipe ativo e não ambíguo para o peer de saída.
- `register`: o sync gera registros no `db_text` local para o `uac_registrant`, usando
  registrar/AOR/contact/usuário/senha vindos do control plane. Como chamadas entrantes de
  operadoras registradas normalmente chegam sem `Authorization` no INVITE, o Inbound deve ter
  `VspAllowedSourceAddresses` preenchido com os IPs autorizados da operadora quando o match não
  puder ser feito por usuário de autenticação. Como o módulo oficial mantém esses registros em
  memória, alterações são aplicadas em runtime via MI `reg_reload`.
- `ip_digest`: reservado para operadoras que exigem IP fixo mais desafio digest em chamadas
  originadas; a política fica no control plane e deve ser tratada como caso explícito.
- `none`: somente para cenários internos controlados, nunca como padrão de operadora externa.

O estado de registro e health deve ser reportado para `/api/v1/sbc/runtime/peer-status`. O
`uac_registrant` mantém estados internos consultáveis via MI; o contrato do mnscloud armazena o
resultado consolidado em `VoipSbcPeer`.

## Audio, media e codecs

- OpenSIPS não processa áudio diretamente; ele controla sinalização SIP.
- O áudio RTP/SRTP é ancorado no `mnscloud-media` via `rtpengine` quando o servidor SBC tem um
  `RealtimeMediaServer` associado.
- Sem `RealtimeMediaServer`, o SBC sinaliza chamadas sem media relay e o RTP depende do caminho
  direto entre as pontas.
- Políticas de codec ficam no control plane do `VoipSbcPipe` e devem ser aplicadas conforme
  instruções retornadas pela API. O padrão operacional é codec pass-through; transcoding deve ser
  tratado como exceção explícita por capacidade do media relay e decisão do master.
- O CDR do Peer é opt-in (`VspEnableCdr = 0` por padrão). Quando ativado no peer de entrada, o runtime envia eventos
  `invite`, `reply`, `cancel`, `bye` e `failed` para `/api/v1/sbc/runtime/accounting` com Call-ID,
  pipe, peer de entrada, origem, destino, saída escolhida e resposta SIP quando aplicável. A API
  persiste os eventos em `VoipSbcCdr` e consolida o status da chamada por Call-ID na listagem.

## Validação, atualização e rollback

```bash
bash scripts/validate-opensips-sbc.sh
bash scripts/update-opensips-sbc.sh --ref v0.1.2
bash scripts/update-latest-opensips-sbc.sh stable
bash scripts/rollback-opensips-sbc.sh
```

- `validate` confere a sintaxe dos scripts e, quando o OpenSIPS está instalado, valida
  `/etc/opensips/opensips.cfg`.
- `update --ref` busca o repositório, faz checkout do ref explícito, executa o instalador e valida.
- `update-latest` resolve o canal em `releases/manifest.json` e chama `update --ref`.
- `rollback` restaura `/etc/opensips/opensips.cfg.bkp`, valida o arquivo restaurado e reinicia
  `opensips.service`.

## Troubleshooting

```bash
opensips -C -f /etc/opensips/opensips.cfg
systemctl status opensips
journalctl -u opensips -f
sngrep -d any port 5060
tcpdump -ni any udp port 5060
```

Para validar heartbeat:

```bash
NODE_UUID="$(tr -d '[:space:]' < /etc/mnscloud/sbc/node.uuid)"
API_TOKEN="$(tr -d '[:space:]' < /etc/mnscloud/sbc/api.token)"
API_BASE="$(tr -d '[:space:]' < /etc/mnscloud/sbc/api.base)"
curl -sS -X POST "${API_BASE}/api/v1/sbc/runtime/heartbeat?node_uuid=${NODE_UUID}&engine=opensips" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "X-SBC-Engine: opensips" \
  --data '{"engine":"opensips","hostname":"sbc-dev1"}'
```
