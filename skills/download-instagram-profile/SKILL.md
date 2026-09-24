---
name: download-instagram-profile
description: "Download media (photos, videos, reels) from Instagram profiles using the Instagram Media Downloader Chrome extension's HTTP API (Native Messaging). Use when the user wants to download Instagram profile content."
---

# Download Instagram Profile

Baixa fotos, vídeos e reels de um perfil do Instagram usando a API HTTP
da extensão "Instagram Media Downloader".

## Pré-requisitos

A extensão **Instagram Media Downloader** precisa estar instalada no Chrome
e o host nativo configurado. A API fica em `http://localhost:9876`.

## API

```
GET /start?profile=<username>&count=<N>   Iniciar download
GET /status                                Status atual
GET /stop                                  Parar
```

Todas as respostas são JSON.

### /start

```bash
curl "http://localhost:9876/start?profile=natgeo&count=30"
```

Parâmetros:

| Param | Default | Descrição |
|-------|---------|-----------|
| `profile` | — | Username do Instagram (obrigatório) |
| `count` | 20 | Quantidade de mídias |

Resposta:

```json
{"success": true, "message": "Started"}
```

### /status

```bash
curl "http://localhost:9876/status"
```

Resposta:

```json
{"state": "collecting", "profile": "natgeo", "collected": 12, "targetCount": 30}
```

Campos de `state`: `idle`, `collecting`, `done`, `error`.

### /stop

```bash
curl "http://localhost:9876/stop"
```

## Aguardar conclusão

O download é assíncrono. Para saber quando terminou, faça polling em `/status`:

```bash
# Exemplo: esperar ate o estado mudar para "done"
while true; do
  resp=$(curl -s http://localhost:9876/status)
  state=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))")
  if [ "$state" = "done" ] || [ "$state" = "error" ]; then
    echo "$resp"
    break
  fi
  sleep 3
done
```

## Fluxo típico para o agente

1. Validar que o username foi fornecido
2. Chamar `GET /start?profile=<username>&count=<N>`
3. Verificar se resposta contém `"success": true`
4. Fazer polling em `/status` até state ser `done` ou `error`
5. Reportar total de mídias baixadas
6. Se state for `error`, reportar falha

## Erros comuns

| HTTP | Motivo |
|------|--------|
| 400 | `profile` não informado |
| 400 | Perfil inválido ou extensão ocupada |
| 500 | Erro interno no host nativo |
| Conexão recusada | Host nativo não está rodando (extensão não carregada ou não conectada) |
