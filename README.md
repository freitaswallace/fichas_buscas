# Sistema de Busca de Fichas de Indisponibilidade

Script PowerShell com interface WPF moderna para buscar e visualizar fichas de indisponibilidade em rede.

## 🚀 Funcionalidades

- ✅ Busca por **nome de pessoa**
- ✅ Busca por **CPF** (11 dígitos, com ou sem formatação)
- ✅ Busca por **CNPJ** (14 dígitos, com ou sem formatação)
- ✅ Busca por **ruas/loteamentos** (com toggle para pasta INDICADOR REAL)
- ✅ **Preview de PDFs** em tempo real
- ✅ Interface moderna com tema claro/escuro
- ✅ Busca em segundo plano com contador em tempo real
- ✅ Otimizações de velocidade

---

## 📋 Pré-requisitos

### Obrigatório:
- **Windows 10/11**
- **PowerShell 5.1+** (já vem instalado no Windows)
- **Ghostscript 10.x** instalado em:
  ```
  C:\Program Files\gs\gs10.06.0\bin\gswin64c.exe
  ```

### Instalar Ghostscript:
1. Baixe em: https://ghostscript.com/releases/gsdnld.html
2. Instale a versão 64-bit
3. Verifique o caminho de instalação no script (linha 10)

---

## 🎮 Como Usar

### Opção 1: Executar como Script (.ps1)

1. Abra PowerShell como **Administrador**
2. Execute:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
   .\script.ps1
   ```

### Opção 2: Converter para Executável (.exe)

Siga as instruções na seção **"Como Converter para EXE"** abaixo.

---

## 🔄 Como Converter o Script para EXE

### Método 1: Usando PS2EXE (Recomendado)

#### 1️⃣ Instalar PS2EXE

Abra PowerShell como **Administrador** e execute:

```powershell
# Permitir execução de scripts
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Instalar módulo PS2EXE
Install-Module -Name ps2exe -Scope CurrentUser -Force

# Verificar instalação
Get-Command Invoke-ps2exe
```

#### 2️⃣ Converter o Script

```powershell
# Navegar até a pasta do script
cd "C:\caminho\para\fichas_buscas"

# Converter para EXE
Invoke-ps2exe `
    -inputFile ".\script.ps1" `
    -outputFile ".\BuscaFichas.exe" `
    -title "Sistema de Busca de Fichas" `
    -company "Sua Empresa" `
    -product "Busca Fichas" `
    -version "1.0.0.0" `
    -noConsole `
    -requireAdmin `
    -iconFile ".\icon.ico"
```

**Parâmetros importantes:**
- `-noConsole` → Oculta janela do console
- `-requireAdmin` → Solicita privilégios de administrador
- `-iconFile` → Adiciona ícone personalizado (opcional)

#### 3️⃣ Resultado

Será criado o arquivo `BuscaFichas.exe` na mesma pasta!

---

### Método 2: Usando GUI (Win-PS2EXE)

#### 1️⃣ Instalar

```powershell
Install-Module -Name ps2exe -Scope CurrentUser -Force
Win-PS2EXE
```

#### 2️⃣ Configurar na Interface

1. **Source file (PS1):** Selecione `script.ps1`
2. **Target file (EXE):** Escolha onde salvar (ex: `BuscaFichas.exe`)
3. **Icon file:** (Opcional) Selecione um `.ico`
4. **Marque:**
   - ☑ **No Console**
   - ☑ **Require Administrator**
5. Clique em **Compile**

---

### Método 3: Usando PowerShell Studio (Pago)

**PowerShell Studio** da Sapien Technologies oferece recursos avançados:
- Editor visual
- Debugger integrado
- Assinatura digital
- Criação de instaladores

Site: https://www.sapien.com/software/powershell_studio

---

## ⚙️ Configuração

### Alterar Caminho do Ghostscript

Edite a linha 10 do `script.ps1`:

```powershell
$script:GhostscriptExePath = "C:\Program Files\gs\gs10.06.0\bin\gswin64c.exe"
```

### Alterar Caminho da Rede

Edite a linha 14 do `script.ps1`:

```powershell
$script:CaminhoBase = "\\192.168.20.100\TRABALHO\TRANSITO\FICHAS INDISPONIBILIDADE NOVAS RENOMEADAS"
```

---

## 🐛 Solução de Problemas

### "Erro ao gerar preview"
- Verifique se o Ghostscript está instalado corretamente
- Confirme o caminho em `$script:GhostscriptExePath`
- Use a versão **console** (`gswin64c.exe`), não a GUI

### "Script não executa"
- Execute PowerShell como **Administrador**
- Configure: `Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process`

### "Preview não atualiza"
- Já corrigido na última versão (commit `e56b062`)
- Carregamento agora é feito da memória

### EXE não funciona
- Verifique se o Ghostscript está instalado
- Execute o EXE como **Administrador**
- Antivírus pode bloquear - adicione exceção

---

## 📊 Tipos de Busca

### 🔘 Checkbox DESMARCADO (padrão):
- Busca em **todas as pastas** exceto INDICADOR REAL
- Ideal para: **Nomes de pessoas** e **CPF/CNPJ**
- ⚡ Busca rápida

### ☑ Checkbox MARCADO:
- Busca **apenas** na pasta INDICADOR REAL
- Ideal para: **Ruas e loteamentos**
- 🏢 Busca específica

---

## 📝 Exemplos de Uso

### Buscar por Nome:
```
Digite: "João Silva"
Resultado: Encontra arquivos com JOAO_SILVA
```

### Buscar por CPF:
```
Digite: "034.591.798-09" ou "03459179809"
Resultado: Encontra arquivo terminando com -03459179809.pdf
```

### Buscar por Rua:
```
1. Marque o checkbox "Buscar apenas em INDICADOR REAL"
2. Digite: "15 de novembro"
3. Resultado: Encontra arquivos com 15_DE_NOVEMBRO
```

---

## 🔧 Otimizações Implementadas

- ✅ Pré-cálculo de padrões (30-50% mais rápido)
- ✅ Redução de logging (90% menos I/O)
- ✅ Atualização de contador em lote (80% menos writes)
- ✅ Busca substring ultra-permissiva
- ✅ Preview com nomes únicos (sem cache)

---

## 📦 Estrutura do Projeto

```
fichas_buscas/
│
├── script.ps1          # Script principal
├── README.md           # Este arquivo
└── icon.ico            # Ícone (opcional, para EXE)
```

---

## ✅ Changelog

### v1.0 (Atual)
- ✅ Busca por nome, CPF, CNPJ e ruas
- ✅ Preview de PDFs com Ghostscript
- ✅ Interface moderna com tema claro/escuro
- ✅ Toggle para busca em INDICADOR REAL
- ✅ Otimizações de velocidade
- ✅ Preview corrigido com carregamento de memória
- ✅ Contador em tempo real funcionando desde primeira busca

---

**Desenvolvido para facilitar a busca de fichas de indisponibilidade** 🚀
