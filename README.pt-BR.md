<p align="center">
  <img src="docs/assets/banner.svg" width="100%" alt="restic-twin: um histórico criptografado para voltar no tempo e uma cópia comum que você só abre." />
</p>

<h1 align="center">restic-twin</h1>

<p align="center"><strong>Sua pasta de projetos com backup todo dia num segundo disco: um histórico criptografado do restic para voltar no tempo e uma cópia comum que você abre no Explorer ou no Finder.</strong></p>

<p align="center">
  <a href="#instalação">Instalação</a> ·
  <a href="#macos-beta">macOS (beta)</a> ·
  <a href="#como-é-um-dia">Como é um dia</a> ·
  <a href="docs/configuration.md">Configuração</a> ·
  <a href="docs/restore.md">Restauração</a> ·
  <a href="docs/troubleshooting.md">Problemas</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/thalesholleben/restic-twin/actions/workflows/ci.yml"><img src="https://github.com/thalesholleben/restic-twin/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/licen%C3%A7a-MIT-2e9d7f?style=flat-square&labelColor=171717" alt="Licença MIT" /></a>
  <a href="#requisitos"><img src="https://img.shields.io/badge/Windows-10%20%7C%2011-a0a29a?style=flat-square&labelColor=171717" alt="Windows 10 ou 11" /></a>
  <a href="#macos-beta"><img src="https://img.shields.io/badge/macOS-beta-a0a29a?style=flat-square&labelColor=171717" alt="macOS, beta" /></a>
  <a href="#requisitos"><img src="https://img.shields.io/badge/PowerShell-5.1%20%7C%207-2e9d7f?style=flat-square&labelColor=171717" alt="PowerShell 5.1 ou 7" /></a>
  <a href="scripts/install-restic.ps1"><img src="https://img.shields.io/badge/restic-0.19.0%20fixado-a0a29a?style=flat-square&labelColor=171717" alt="restic 0.19.0, versão fixada" /></a>
</p>

## O problema

Um segundo disco no PC é o backup mais barato que existe, e a maioria das pessoas usa arrastando pastas
para lá de vez em quando. Essa cópia está sempre um pouco velha e guarda uma versão de cada arquivo:
você sobrescreve algo na segunda, percebe na quarta, e a versão boa sumiu dos dois discos.

O [restic](https://restic.net) resolve a parte do histórico, com snapshots criptografados e
deduplicados, um por dia, gastando muito pouco espaço a mais. Só que um repositório restic não abre no
Explorer, e rodar o restic todo dia no Windows como serviço, com VSS, retenção, logs e uma falha que dá
para enxergar, é um fim de semana de script fácil de errar nos detalhes.

O restic-twin é esse fim de semana, pronto e testado. Ele começou como o backup do workspace de um
desenvolvedor, rodando todo dia desde meados de 2026, e a versão pública corrige o que esse uso diário
revelou, listado em [o que o uso diário mostrou](#o-que-o-uso-diário-mostrou). Roda no Windows e, em
beta, no macOS.

## O que você ganha

No segundo disco, dentro da pasta que você escolher:

```
E:\restic-twin\
  mirror\        cópia comum do último backup: abra, pesquise, copie o que precisar
  history\       o repositório restic criptografado, um snapshot por dia
  reports\2026\09\
    changes_2026-09-23_190002_c067aab9.md     o que mudou desde ontem, para ler
    changes_2026-09-23_190002_c067aab9.csv    o mesmo, para planilha
    changes_2026-09-23_190002_c067aab9.jsonl  tudo o que o restic informou, para script
  logs\          latest.json, runs.jsonl e um conjunto de logs por execução
  recovery\      a senha do repositório e um README de como restaurar em qualquer lugar
  hot-copies\    cópias frequentes dos poucos arquivos que você listar, se listar
  restores\      onde o restore.ps1 coloca o que você trouxer de volta
```

## Como é um dia

<p align="center">
  <img src="docs/assets/flow.svg" width="630" alt="A pasta de origem vai para o restic backup, que grava um snapshot no histórico; a diferença entre dois snapshots vira o relatório; depois o robocopy atualiza o espelho; as hot copies rodam sozinhas a cada cinco minutos." />
</p>

1. Às 19:00 a tarefa diária começa, como SYSTEM. Se o PC estava desligado, ela roda na próxima vez que
   ele ligar.
2. O restic tira um snapshot da origem pelo VSS, então arquivos que outros programas mantêm abertos são
   lidos como estavam num mesmo instante.
3. O restic compara com o snapshot anterior e o relatório de alterações é gravado.
4. Só depois o robocopy atualiza o espelho. Um arquivo que você apagou sem querer hoje some do espelho
   também, mas continua no snapshot de ontem.
5. A retenção guarda um snapshot para cada um dos últimos 7 dias e um para cada um dos últimos 6 meses.
   Uma vez por semana o restic também limpa os dados sem uso e confere o repositório.

No Mac o mesmo dia roda pelo launchd, como root, com o rsync no espelho e sem VSS, e um Mac que estava
desligado às 19:00 faz o backup dentro da hora seguinte a ligar. Veja [macOS](#macos-beta).

As hot copies servem para os dois ou três arquivos que mudam o dia inteiro, como um arquivo de notas ou
um quadro, em que uma cópia por dia é pouco. A cada 5 minutos, enquanto você está logado, cada conjunto
de arquivos listado é copiado inteiro para uma pasta com data e hora, só quando algum deles mudou, e só
as 12 últimas versões ficam. São arquivos comuns, não precisa restaurar nada.

## Instalação

### Requisitos

- Windows 10 ou 11 e um segundo disco (interno, USB ou qualquer coisa com letra de unidade).
- PowerShell 7 é o recomendado; o Windows PowerShell 5.1, que vem em todo Windows, também funciona.
- Direitos de administrador na instalação: a tarefa diária roda como SYSTEM e usa VSS.

O próprio restic é baixado pelo instalador da release oficial no GitHub e conferido contra um checksum
fixado no [install-restic.ps1](scripts/install-restic.ps1). Não precisa de mais nada.

### Passos

```powershell
git clone https://github.com/thalesholleben/restic-twin.git
cd restic-twin
Copy-Item config\settings.example.psd1 config\settings.psd1
notepad config\settings.psd1    # defina SourcePath e DestinationRoot e salve
```

Depois, num PowerShell aberto como Administrador, na mesma pasta:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\install.ps1
```

O instalador cria as pastas de destino, uma senha aleatória para o repositório e o repositório restic.
Nenhuma outra conta local consegue ler essas pastas, e a sua lê mas não altera o que a tarefa diária
grava. Em seguida ele se copia para `C:\Program Files\restic-twin` e registra as tarefas de lá. Ele
avisa se a origem e o destino estão no mesmo disco físico.

**Copie a senha agora.** Ela fica em `recovery\restic-password.txt`, dentro do destino. Guarde num
gerenciador de senhas: sem ela ninguém consegue abrir o histórico, nem você.

Rode o primeiro backup em vez de esperar as 19:00:

```powershell
Start-ScheduledTask -TaskName 'restic-twin daily backup'
```

### macOS (beta)

Os mesmos scripts rodam no Mac, Apple silicon ou Intel. O launchd roda o backup diário como root, do
jeito que o Agendador roda como SYSTEM, o rsync atualiza o espelho, e as pastas que o root grava
pertencem ao root, modo 700, com uma entrada que deixa a sua conta ler. Beta quer dizer que passa nos
mesmos testes num runner macOS do GitHub, inclusive numa instalação real como root com um disco
montado em `/Volumes`, mas ainda não passou por uso diário num Mac.
[Conte o que encontrar](https://github.com/thalesholleben/restic-twin/issues).

Você precisa de:

- PowerShell 7 instalado para o Mac inteiro, com `brew install --cask powershell` ou o `.pkg` das
  [releases do PowerShell](https://github.com/PowerShell/PowerShell/releases). A tarefa diária roda
  ele como root, então tem que ser a cópia em `/usr/local/microsoft/powershell/7`, que só o root
  consegue alterar.
- Um disco de backup formatado em APFS ou Mac OS Expandido, com "Ignorar propriedade neste volume"
  desmarcado na janela Obter Informações dele. Em exFAT funciona, mas nada ali fica privado.
- Acesso Total ao Disco para esse PowerShell se a origem estiver em Mesa, Documentos ou Transferências,
  ou se o macOS negar à tarefa o disco de backup: veja
  [problemas comuns](docs/troubleshooting.md#operation-not-permitted-on-macos). Uma origem em outro
  lugar, como `~/Projects`, não precisa de nada.

```sh
git clone https://github.com/thalesholleben/restic-twin.git
cd restic-twin
cp config/settings.example.macos.psd1 config/settings.psd1
nano config/settings.psd1      # defina SourcePath e DestinationRoot e salve
sudo pwsh ./scripts/install.ps1
sudo launchctl kickstart system/com.restic-twin.daily      # o primeiro backup, agora
```

O instalador faz o mesmo que no Windows, com `/Library/Application Support/restic-twin` como cópia
instalada. A tarefa diária roda no `DailyAt` e também a cada hora com `-IfDue`, que só faz backup
quando nada deu certo desde o último `DailyAt`: o launchd não roda uma tarefa que ele perdeu com o Mac
desligado. A senha fica em `recovery/restic-password.txt`, que você consegue ler: copie agora.

## Uso no dia a dia

| Você quer | Rode |
|---|---|
| Ver a última execução, a próxima e o que precisa de você | `.\scripts\status.ps1` |
| Fazer backup agora, como administrador | `& "$env:ProgramFiles\restic-twin\scripts\backup.ps1"` |
| Trazer o último snapshot para uma pasta nova | `.\scripts\restore.ps1` |
| Trazer uma pasta de um snapshot antigo | `.\scripts\restore.ps1 -Snapshot 4bd2e9a1 -Include '/docs'` |
| Mudar uma configuração | edite `config\settings.psd1` e rode `.\scripts\install.ps1` de novo, como administrador |
| Remover as tarefas e a cópia instalada, mantendo todos os backups | `.\scripts\uninstall.ps1`, como administrador |

No macOS os mesmos scripts rodam com `pwsh ./scripts/status.ps1` e `pwsh ./scripts/restore.ps1`, e
com `sudo` onde a tabela diz administrador: `sudo pwsh ./scripts/install.ps1`, `sudo pwsh
./scripts/uninstall.ps1`, e um backup agora com `sudo pwsh '/Library/Application
Support/restic-twin/scripts/backup.ps1'`.

Para a versão de ontem de um arquivo, o espelho tem a de hoje e o histórico tem o resto; veja
[restauração](docs/restore.md). O `status.ps1` também avisa quando as tarefas ainda rodam uma cópia
antiga das suas configurações.

## Um relatório de alterações

Toda execução depois da primeira grava um, em três formatos. O Markdown fica assim:

```markdown
# Changes in backup 2026-09-23_190002

- Previous snapshot: `8f1c2d3e...`
- Current snapshot: `c067aab9...`
- Changed paths: 42
- Added to the snapshot: 3.1 MB

## By action

- modified: 31
- added: 9
- removed: 2
```

Depois vêm as áreas e as extensões que mais mudaram e os 100 primeiros caminhos. O CSV tem uma linha
por caminho, e o JSONL guarda cada linha que o restic imprimiu. Um exemplo completo está em
[docs/examples](docs/examples/change-report.md).

## Travas de segurança

- **O espelho nunca é atualizado numa pasta que ele não criou.** O `/MIR` do robocopy e o `--delete`
  do rsync apagam o que o destino tem e a origem não, então a pasta do espelho precisa estar vazia ou
  ter o marcador que o restic-twin gravou nela com o nome desta mesma origem.
- **O histórico é gravado antes do espelho**, então uma exclusão sempre continua no snapshot anterior
  quando o espelho a perde.
- **A restauração vai para uma pasta nova**, nunca por cima de uma existente e nunca dentro da origem.
- **O instalador nunca troca uma senha.** Quando existe um repositório e o arquivo de senha sumiu, ele
  para em vez de criar uma senha nova que não abriria o histórico.
- **Tudo o que roda como SYSTEM ou root roda de uma cópia que só administrador altera**, o Program
  Files no Windows e o `/Library/Application Support` no macOS, com um PowerShell que só eles
  conseguem trocar. Um script no seu perfil executado pelo SYSTEM toda noite entregaria o SYSTEM para
  qualquer coisa rodando como você.
- **O que o SYSTEM ou o root grava, a sua conta só lê.** Depois de instaladas as tarefas, o
  histórico, o espelho, os relatórios e os logs pertencem aos Administradores (ao root, no macOS).
  Nada rodando como você, ransomware incluso, consegue apagar ou criptografar esses arquivos, trocar
  um arquivo que a tarefa diária relê ou desviar as gravações dela com uma junction ou um link. Você
  continua abrindo, pesquisando e copiando tudo, e mantém controle total das hot copies e das
  restaurações.
- **Uma execução que não conseguiu ler um arquivo falha e diz qual é**, em vez de relatar sucesso com
  um buraco no snapshot. A correção é uma linha na lista de exclusões ou um ajuste de permissão.
- **As configurações são conferidas antes de qualquer coisa rodar**: origem dentro do destino, senha
  dentro do espelho, chave escrita errado ou arquivo listado duas vezes param com uma mensagem que diz o
  que corrigir.

## O que o uso diário mostrou

A versão pessoal rodou três meses antes desta. Os logs dela, e o próprio porte, revelaram estes
problemas, todos corrigidos e cobertos por teste aqui:

| O que deu errado | Como apareceu | O que o restic-twin faz |
|---|---|---|
| Todo caminho com acento saía embaralhado nos relatórios | Nomes de pasta no CSV viravam mojibake | Troca o console para UTF-8 antes de chamar o restic: tarefa agendada roda na página de código OEM |
| "Tentar 3 vezes a cada 15 minutos" nunca tentou de novo | Doze execuções com falha, cada uma seguida só pela do dia seguinte | Diz isso claramente: o Agendador reinicia a tarefa que não conseguiu iniciar, não a que sai com código 1 |
| Uma execução manual e a agendada podiam se sobrepor | Achado lendo o código | A trava de execução é `Global\`: a execução agendada vive em outra sessão |
| Um nome da lista de exclusões igual a uma pasta acima da origem excluía tudo | Achado pelos testes: uma origem dentro de `...\build\` gerou snapshot vazio com código 0 | Ancora cada padrão de exclusão dentro da origem, e o restic passa a concordar com o robocopy |
| A manutenção semanal só rodava aos domingos | Achado lendo o código: um PC desligado aos domingos nunca faz a limpeza | Roda quando a última tem 7 dias |

## Limites

- **Não é backup fora de casa.** Um segundo disco protege de um disco que pifa, dos seus próprios
  erros e de ransomware rodando como você, não de roubo, incêndio ou qualquer coisa que consiga
  direitos de administrador. Copie o histórico para outro lugar com `restic copy`, deixe o disco
  desconectado entre os backups, ou os dois.
- **Uma pasta de origem por máquina.** Coloque o que você protege dentro de uma pasta só.
- **O macOS está em beta.** Passa nos mesmos testes do Windows num runner macOS do GitHub, mais uma
  instalação real como root, e ainda não passou por uso diário num Mac. Lá não existe VSS: um arquivo
  que um programa está gravando durante o backup é lido como está naquele momento.
- **Só Windows e macOS.** Não existe adaptador para Linux.
- **Um arquivo sempre aberto em modo exclusivo**, como um banco de dados rodando ou um disco de VM, fica
  no snapshot (pelo VSS) mas faz o espelho falhar. Liste o nome dele em `config\excludes-mirror.txt`.

## Próximos passos

- Uma cópia do histórico fora de casa com `restic copy`, para um NAS ou um bucket na nuvem.
- Um aviso quando uma execução falha.
- Mais de uma pasta de origem.

## Documentação

[Como funciona](docs/how-it-works.md), [configuração](docs/configuration.md),
[restauração](docs/restore.md), [problemas comuns](docs/troubleshooting.md), [segurança](SECURITY.md),
[como contribuir](CONTRIBUTING.md) e o [changelog](CHANGELOG.md), em inglês. Agentes de código começam
pelo [AGENTS.md](AGENTS.md).

## Licença

[MIT](LICENSE), pela [SyntaxLab](https://syntaxlab.com.br). O restic é um projeto separado, sob a
licença BSD 2-Clause; o restic-twin baixa a release oficial e não a redistribui.
