<div align="center">

# RaveTool

**Inspecione e edite relatórios `.rav` do Rave Reports pela linha de comando — sem abrir o designer.**

[![Delphi](https://img.shields.io/badge/Delphi-11%20Alexandria-b71c1c)](https://www.embarcadero.com/products/delphi)
[![Rave Reports](https://img.shields.io/badge/Rave%20Reports-2025-1565c0)](https://www.nevrona.com/rave/)
[![Plataforma](https://img.shields.io/badge/plataforma-Windows%20x86-555555)]()

</div>

---

Arquivo `.rav` é binário. Para trocar o rótulo de uma coluna você abre o Rave, caça o componente no meio do layout, altera e salva. Multiplique isso por 300 pastas de clientes com o mesmo relatório levemente diferente e o trabalho vira inviável — sem contar que o diff no Git não diz nada.

O RaveTool carrega o projeto usando a própria API do Rave (`TRaveProjectManager`), navega os componentes por RTTI e grava de volta. Com isso dá para **ler o layout inteiro como texto** e **aplicar alterações por script**.

```bash
# o que tem dentro deste relatório?
ravtool dump ImpPedido.rav layout.txt

# tira a coluna de IPI (rótulo + dado) de todos os clientes
for /d %c in (C:\Sistemas\_*) do ravtool del "%c\RAVE\ImpPedido.rav" Text14 DataText11
```

## Recursos

- 📄 **Dump em texto** — árvore completa do projeto: DataViews e seus campos, páginas globais, relatórios, bandas e componentes, com as propriedades publicadas de cada um.
- ✏️ **Edição por script** — alterar propriedade, remover, duplicar e criar componentes, tudo por linha de comando.
- 🔗 **Referências por nome** — `DataView=dvItensPedido`, `Controller=Detalhe`: a ferramenta resolve a referência ao componente.
- 🛟 **Backup automático + validação** — cada gravação faz backup e roda `Compile` antes; se o projeto não compilar, **nada é gravado**.
- 🔁 **Converte de quebra** — o `Save` grava no formato 2025, então relatórios ainda no formato 2006 são migrados no caminho.

## Começando

### Requisitos

- Delphi 11 (RAD Studio 22.0), Win32
- Rave Reports 2025 em `C:\Program Files (x86)\Nevrona\Rave2025`

### Compilando

```bash
dcc32 -B -U"C:\Program Files (x86)\Nevrona\Rave2025\D11-32" ^
      -NS"System;System.Win;Winapi;Vcl;Vcl.Imaging;Data;Data.Win;Xml" ^
      ravtool.dpr
```

Ou abra o `ravtool.dpr` no RAD Studio, acrescente `...\Rave2025\D11-32` ao library path do projeto e compile em Win32.

> **Nota:** a ferramenta precisa dos 11 módulos de sistema do Rave (`.rvc`) na pasta do executável. Ela copia sozinha de `Rave2025\Bin` na primeira execução. Em máquina sem o Rave instalado, copie os `.rvc` na mão.

### Primeiro comando

Comece sempre pelo `dump` — é ele que revela os nomes dos componentes, que são o que todos os outros comandos recebem:

```bash
ravtool dump ImpPedido.rav layout.txt
```

```
- TRaveDataBand "Detalhe"
    DataView=<dvItensPedido>  DetailKey=ID_PEDIDO  Height=0,1899  Name=Detalhe
- TRaveDataText "DataText24"
    DataField=QTDE+' '+UNIDMED  DataView=<dvItensPedido>  FontJustify=pjRight
    Left=4,09  Name=DataText24  Top=0,0283  Width=0,46
- TRaveCalcText "CalcText1"
    CalcType=ctSum  Controller=<Detalhe>  DataField=VALORPRODUTOS  DataView=<dvItensPedido>
    DisplayFormat=R$#,##0.00  Left=6,8679  Name=CalcText1  Text=Sum(VALORPRODUTOS)
```

Pronto. Agora você sabe que a coluna de quantidade é o `DataText24` e o totalizador é o `CalcText1`.

## Comandos

| Comando | Sintaxe | O que faz |
|---|---|---|
| `dump` | `ravtool dump <arq.rav> [saida.txt]` | Lista a árvore completa do projeto |
| `set` | `ravtool set <arq.rav> <Componente> <Prop> <Valor>` | Altera uma propriedade |
| `del` | `ravtool del <arq.rav> <Comp> [<Comp> ...]` | Remove componentes |
| `copy` | `ravtool copy <arq.rav> <Origem> <NovoNome> [Prop=Valor ...]` | Duplica um componente |
| `add` | `ravtool add <arq.rav> <Classe> <NovoNome> <Pai> [Prop=Valor ...]` | Cria um componente novo |

### Exemplos

Esconder um campo, sem remover:

```bash
ravtool set ImpPedido.rav DataText11 Visible False
```

Remover uma coluna inteira — rótulo do cabeçalho e o dado da banda de detalhe:

```bash
ravtool del ImpPedido.rav Text14 DataText11
```

Duplicar um totalizador que já existe, trocando o campo e a posição:

```bash
ravtool copy ImpPedido.rav CalcText4 CalcTextEmb DataField=_EMBALAGEM_QTDE Left=6.9279 Top=0.27
```

Criar componentes do zero dentro de uma banda:

```bash
ravtool add ImpRomaneio.rav TRaveText Rotulo Rodape "Text=Total de embalagens:" Left=4.6 Top=0.06

ravtool add ImpRomaneio.rav TRaveCalcText Soma Rodape ^
       DataView=dvLista DataField=_EMBALAGEM CalcType=ctSum Controller=Produtos ^
       Left=6.15 Top=0.06
```

### Valores aceitos em `Prop=Valor`

| Tipo | Exemplo |
|---|---|
| Texto | `Text=Total de embalagens:` |
| Número | `Left=6.9279` |
| Enumerado | `FontJustify=pjRight`, `CalcType=ctSum` |
| Conjunto | `ReprintLocs=[plDetail,plBodyFooter]` |
| Referência a componente | `DataView=dvItensPedido`, `Controller=Detalhe` |

> **Dica:** valores com espaço precisam de aspas — `"Text=Total de embalagens:"`.

## Como funciona a gravação

Todo comando que grava segue três passos:

1. **Backup** — copia para `arquivo.rav.bak-AAAAMMDD-HHNNSS` ao lado do original.
2. **Compile** — roda o compilador do Rave no projeto. Se falhar, o comando aborta com o erro e **o arquivo original fica intacto**.
3. **Save** — só então grava, no formato Rave 2025.

Relatórios que ainda estavam no formato 2006 são convertidos nesse momento. É esperado o arquivo crescer bastante — ele passa a carregar o módulo compilado embutido.

## Detalhes de implementação

- Antes do `Compile`, aplica o auto-fix do `Error #15 - Duplicate identifier`: renomeia o relatório cujo `Name` colide com o nome do projeto, de um dataview ou de uma página, preservando o `FullName`.
- No `copy`, o componente é gravado no stream **já com o nome novo** e o nome do original é restaurado em seguida. Sem isso, o `ReadComponent` estoura com *"a component named X already exists"*.
- O dump omite propriedades vazias, zeradas e um punhado de ruído (`Tag`, `Cursor`, `MirrorPoint`, eventos) para o arquivo ficar legível.

## Compatibilidade

| Ambiente | Situação |
|---|---|
| Rave Reports 2025 + Delphi 11 Win32 | ✅ testado |
| Rave Reports 2006 (arquivos de entrada) | ✅ convertidos na gravação |
| Delphi 10.x / 12 | ❔ não testado |
| Win64 | ❌ não testado |

## Limitações

- Um comando por execução. Para várias alterações no mesmo relatório, encadeie chamadas — cada uma gera seu próprio backup.
- `add` só coloca componentes dentro de um pai já existente; não cria bandas nem páginas.
- Não mexe em scripts de evento (Event Editor). Relatório cujo script não compila no Rave 2025 é recusado na gravação e precisa ser ajustado no designer.
- Propriedades aninhadas (`Font.Size`, por exemplo) não são acessíveis por `Prop=Valor` — apenas as de primeiro nível.

## Relacionado

**RaveBatchCompile** — converte `.rav` do Rave 2006 para 2025 em lote. O RaveTool reaproveita dele a forma de carregar, compilar e gravar os projetos.
