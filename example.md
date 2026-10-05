

---

## 1) Autenticação — gerar token

```bash
curl -s -X POST http://10.0.0.147/api/auth/token
```

Resposta:
```json
{ "success": true, "message": "Token gerado com sucesso", "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...." }
```

Guardar o token numa variável (para reutilizar nos próximos comandos):
```bash
TOKEN=$(curl -s -X POST http://10.0.0.147/api/auth/token | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
echo "$TOKEN"
```

Validar o token:
```bash
curl -s http://10.0.0.147/api/auth/validate -H "Authorization: Bearer $TOKEN"
```

---

## 2) Registro de contrato (autenticado)

```bash
curl -s -X POST http://10.0.0.147/api/contracts/ \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "regConId": "VFIN-2025-001",
    "numeroContrato": "87686",
    "dataContrato": "2025-09-11",
    "vehicleData": {
      "regConId": "VFIN-2025-001",
      "numeroContrato": "87686",
      "dataContrato": "2025-09-11",
      "nomeAgenteFinanceiro": "CREDORA INTERNA",
      "cnpjAgenteFinanceiro": "11204397000150",
      "cpfCnpjProprietario": "64687376487",
      "nomeProprietario": "ANDRE SANTOS",
      "chassiVeiculo": "983279794327897",
      "placaVeiculo": "PL87686",
      "marcaVeiculo": "FIAT",
      "modeloVeiculo": "ARGO",
      "modelName": "ARGO",
      "tipoRestricacaoContrato": "ALIENACAO FIDUCIARIA",
      "valorTotalContrato": "30000.00",
      "quantidadeParcelasContrato": "36",
      "taxaJurosMesContrato": "1.00",
      "veiculoZeroKm": true,
      "anoFabricacaoVeiculo": "2025",
      "anoModeloVeiculo": "2025"
    }
  }'
```

Resposta (`201 Created`):
```json
{
  "success": true,
  "message": "Contrato registrado com sucesso",
  "regConId": "VFIN-2025-001",
  "metadataHash": "854d3c0bc68726bb60f799310320787696303d4c87c0fbe7ee96f3fc98cff59a",
  "txHash": "0x4cbd7fcc2eb6d0a8fbb7a04b3fbf35f724892e2899f3d6567c531a3b993ecb33"
}
```

> **Obrigatórios (senão `InvalidInput`):** `regConId`, `numeroContrato`, `dataContrato` e, dentro de `vehicleData`: `chassiVeiculo`, `placaVeiculo`, `marcaVeiculo`, `modeloVeiculo`, `valorTotalContrato` (> 0). Os demais campos vão para o metadata off-chain.

---

## 3) Consultar o contrato registrado (sem auth)

```bash
# híbrido (on-chain + off-chain) pelo regConId
curl -s http://10.0.0.147/api/contracts/VFIN-2025-001

# pelo chassi
curl -s http://10.0.0.147/api/contracts/chassis/983279794327897

# só on-chain pelo registry
curl -s http://10.0.0.147/api/blockchain/contract/registry/VFIN-2025-001
```

---

## Fluxo completo num bloco

```bash
BASE=http://10.0.0.147

# 1. token
TOKEN=$(curl -s -X POST $BASE/api/auth/token | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

# 2. registro
curl -s -X POST $BASE/api/contracts/ \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"regConId":"VFIN-2025-001","numeroContrato":"87686","dataContrato":"2025-09-11","vehicleData":{"regConId":"VFIN-2025-001","numeroContrato":"87686","dataContrato":"2025-09-11","cpfCnpjProprietario":"64687376487","nomeProprietario":"ANDRE SANTOS","nomeAgenteFinanceiro":"CREDORA INTERNA","cnpjAgenteFinanceiro":"11204397000150","chassiVeiculo":"983279794327897","placaVeiculo":"PL87686","marcaVeiculo":"FIAT","modeloVeiculo":"ARGO","modelName":"ARGO","tipoRestricacaoContrato":"ALIENACAO FIDUCIARIA","valorTotalContrato":"30000.00","quantidadeParcelasContrato":"36","taxaJurosMesContrato":"1.00","veiculoZeroKm":true,"anoFabricacaoVeiculo":"2025","anoModeloVeiculo":"2025"}}'

# 3. consulta
curl -s $BASE/api/contracts/VFIN-2025-001
```
